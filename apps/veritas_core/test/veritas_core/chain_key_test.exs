defmodule Veritas.Core.ChainKeyTest do
  @moduledoc """
  The chain key ring is **one key per host**, and the file that holds it is
  written **once**.

  Two processes that start at the same time — the server booting while the
  CLI runs — must not each mint a key. A ring two processes share is a ring
  whose file holds one of their keys while the other signs with the key only
  it holds, and every event that process signed then verifies as **tampered**
  once anything restarts. So the ring is published **exclusively**, and a
  writer that loses the race adopts the key on disk rather than the one it
  generated.

  A ring file that cannot be read is **not** replaced either. It may be the
  key that signed every event in the chain, and replacing it silently re-keys
  the Audit Log — every event the old key signed stops verifying.

  These tests therefore race two **operating system processes** against one
  another, because a race that two tasks in one VM stage is not a race: the
  ring is cached in `:persistent_term`, and one VM has one cache.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Audit.ChainKey

  # The writer a child process runs: it waits for its siblings, so that the
  # race is a race and not a queue, and then publishes the ring.
  @writer """
  :ok = File.write!(System.get_env("VERITAS_RING_READY"), "")

  wait = fn wait ->
    if File.exists?(System.get_env("VERITAS_RING_GO")) do
      :ok
    else
      Process.sleep(5)
      wait.(wait)
    end
  end

  wait.(wait)

  case Veritas.Core.Audit.ChainKey.load() do
    {:ok, ring} ->
      key = Enum.find(ring.keys, &(&1.id == ring.current))
      IO.puts("PATH " <> Veritas.Core.Audit.ChainKey.default_key_file())
      IO.puts("SECRET " <> Base.encode16(key.secret, case: :lower))

    {:error, reason} ->
      IO.puts("ERROR " <> inspect(reason))
  end
  """

  setup do
    directory = unique_dir("veritas_ring")

    File.mkdir_p!(directory)

    # The ring this test is about is the **default** one, in a directory of
    # the test's own: no other process on the machine can reach it, and the
    # ring the machine would use for real is not touched.
    previous = %{
      dir: System.get_env("VERITAS_CHAIN_KEY_DIR"),
      key: System.get_env("VERITAS_CHAIN_KEY"),
      file: System.get_env("VERITAS_CHAIN_KEY_FILE")
    }

    System.put_env("VERITAS_CHAIN_KEY_DIR", directory)
    System.put_env("VERITAS_CHAIN_KEY", "")
    System.put_env("VERITAS_CHAIN_KEY_FILE", "")
    ChainKey.reset()

    on_exit(fn ->
      restore("VERITAS_CHAIN_KEY_DIR", previous.dir)
      restore("VERITAS_CHAIN_KEY", previous.key)
      restore("VERITAS_CHAIN_KEY_FILE", previous.file)
      ChainKey.reset()
    end)

    {:ok, directory: directory, ring_path: Path.join(directory, "chain-key.json")}
  end

  describe "the default ring" do
    test "is created once, with a key only its owner can read", %{ring_path: path} do
      {:ok, ring} = ChainKey.load()

      assert ring.current == "default"
      assert [%{id: "default"}] = ring.keys
      assert File.exists?(path)

      # The key is the host's secret. Anyone who can read the file can forge
      # the Audit Log.
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "is the same ring for the writer that comes second", %{ring_path: path} do
      {:ok, first} = ChainKey.load()
      written = File.read!(path)

      # A second process, with an empty cache, reads the ring that is there.
      ChainKey.reset()
      {:ok, second} = ChainKey.load()

      assert second == first
      assert File.read!(path) == written
    end

    test "is not replaced when the file cannot be read", %{ring_path: path} do
      # A file that is not the document it should be: it may be the key that
      # signed every event in the chain, and replacing it re-keys the Audit
      # Log without saying so.
      File.write!(path, "this is not a key ring")

      assert {:error, reason} = ChainKey.load()
      assert reason =~ path

      # The file is left exactly as it was found.
      assert File.read!(path) == "this is not a key ring"
    end

    test "is not replaced when the file is empty", %{ring_path: path} do
      # An empty file is what a writer that died between creating the file
      # and writing it leaves behind. It holds no key, and it is not the
      # product's to replace: the operator is told, and the file stays.
      File.write!(path, "")

      assert {:error, reason} = ChainKey.load()
      assert reason =~ path

      assert File.read!(path) == ""
    end
  end

  describe "two writers that find no ring at the same time" do
    test "end up with the same key, and that key is the one on disk" do
      # The race is run more than once: a race that one run does not lose is
      # not a race that has been shown to be safe.
      for round <- 1..3 do
        ring_directory = unique_dir("veritas_ring_round")
        File.mkdir_p!(ring_directory)
        ring_path = Path.join(ring_directory, "chain-key.json")

        # Nothing is there for either of them to find: both writers start
        # with no ring at all, which is the situation the race is about.
        refute File.exists?(ring_path)

        {secrets, paths, statuses} = race(ring_directory, ring_path)

        assert Enum.all?(statuses, &(&1 == 0)),
               "a writer failed to publish the ring: #{inspect(statuses)}"

        # Each writer read the ring file **for itself**, in its own VM: its
        # own cache, its own read of the file. Two writers that shared a
        # cache would agree for the wrong reason.
        assert paths == [ring_path, ring_path],
               "the writers did not both read #{ring_path}: #{inspect(paths)}"

        # One key, not two: the file holds one key and both writers use it.
        assert [_secret] = Enum.uniq(secrets),
               "two writers published two keys in round #{round}: #{inspect(secrets)}"

        # And the key they both hold is the key on disk.
        document = ring_on_disk(ring_path)
        assert [%{"id" => "default", "secret" => secret}] = document["keys"]
        assert secret == hd(secrets)
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Two operating system processes, released at the same moment, publishing
  # the same ring. What they print is the key each of them ended up signing
  # with, and the file each of them read.
  defp race(directory, ring_path) do
    go = Path.join(directory, "go-#{System.unique_integer([:positive])}")
    ready = Path.join(directory, "ready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ready)

    writers =
      for name <- ["a", "b"] do
        Task.async(fn ->
          run_writer(name, ring_path, go, Path.join(ready, name))
        end)
      end

    # Both writers are up and waiting before either of them is let go.
    wait_until(fn ->
      Enum.all?(["a", "b"], fn name -> File.exists?(Path.join(ready, name)) end)
    end)

    File.write!(go, "")

    results = Enum.map(writers, &Task.await(&1, 60_000))

    secrets =
      Enum.map(results, fn {output, _status} ->
        case Regex.run(~r/^SECRET ([0-9a-f]+)$/m, output) do
          [_, secret] -> secret
          _other -> output
        end
      end)

    paths =
      Enum.map(results, fn {output, _status} ->
        case Regex.run(~r/^PATH (.+)$/m, output) do
          [_, path] -> String.trim(path)
          _other -> output
        end
      end)

    statuses = Enum.map(results, fn {_output, status} -> status end)

    {secrets, paths, statuses}
  end

  defp run_writer(name, ring_path, go, ready) do
    script = Path.join([System.tmp_dir!(), "veritas_ring_writer_#{name}.exs"])
    File.write!(script, @writer)

    env = [
      {"VERITAS_CHAIN_KEY_DIR", Path.dirname(ring_path)},
      {"VERITAS_CHAIN_KEY", ""},
      {"VERITAS_CHAIN_KEY_FILE", ""},
      {"VERITAS_RING_GO", go},
      {"VERITAS_RING_READY", ready}
    ]

    System.cmd(elixir(), code_path_args() ++ [script], env: env, stderr_to_stdout: true)
  end

  defp elixir do
    case System.find_executable("elixir") do
      nil -> raise "the elixir executable is not on the PATH; the race cannot be run"
      path -> path
    end
  end

  # The code paths of this VM, so that the writer runs the **compiled** code
  # and not a copy of it. `:code.get_path/0` returns Erlang strings, and
  # `System.cmd/3` wants binaries. A path that is not there is left out: the
  # `elixir` command refuses to start when it is given a path it cannot find.
  #
  # Each path carries its own `-pa`: the option takes **one** path, and the
  # path after it would be taken for the script to run.
  defp code_path_args do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn path -> ["-pa", path] end)
  end

  defp ring_on_disk(path) do
    body = File.read!(path)
    Jason.decode!(body)
  end

  defp wait_until(condition, attempts \\ 200) do
    cond do
      condition.() ->
        :ok

      attempts <= 0 ->
        raise "the writers did not start in time"

      true ->
        Process.sleep(25)
        wait_until(condition, attempts - 1)
    end
  end

  defp unique_dir(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
    )
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
