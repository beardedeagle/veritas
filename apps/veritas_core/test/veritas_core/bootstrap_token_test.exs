defmodule Veritas.Core.BootstrapTokenTest do
  @moduledoc """
  The bootstrap token: where it lives, and who may spend it.

  Two things are proved here, and both are about the token rather than
  about the account it creates:

    * the token is **never on disk in a file another user can read** — not
      the delivery file, not the temporary it is written through, and not
      for the width of a write. The directory that holds it is closed to
      other users as well, because a file's own permissions are the only
      thing standing between a secret and a stranger who can walk into its
      directory;

    * the token is spent **once**: exactly one caller can hold it, even
      when several present it at the same moment, and a token that was
      claimed for work that did not happen is a token again.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.BootstrapToken

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "veritas_token_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.mkdir_p!(directory)

    {:ok, directory: directory}
  end

  describe "where the token lives" do
    test "the directory that holds it is the owner's alone", %{directory: directory} do
      {:ok, _path} = issue(directory)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(directory)

      assert Bitwise.band(mode, 0o077) == 0,
             "the directory holding the token is readable by other users"
    end

    test "every file the token is written to is the owner's alone", %{directory: directory} do
      {:ok, _path} = issue(directory)

      files = Path.wildcard(Path.join(directory, "*"))
      assert files != []

      for file <- files do
        assert {:ok, %File.Stat{mode: mode}} = File.stat(file)

        assert Bitwise.band(mode, 0o077) == 0,
               "#{file} is readable by other users"
      end
    end

    test "the secret is never in a file another user can read", %{directory: directory} do
      reporter = self()
      watcher = spawn(fn -> watch(directory, reporter) end)
      on_exit(fn -> send(watcher, :stop) end)

      # The watcher is running before anything is written.
      assert_receive({:scan, _})

      for _ <- 1..10 do
        {:ok, _path} = issue(directory)
      end

      # Two more scans: they are after the writes, so the watcher has looked
      # at the directory since the secret was on it.
      assert_receive({:scan, _})
      assert_receive({:scan, _})

      refute_received({:exposed, _file})
    end
  end

  describe "spending the token" do
    test "only one of several callers that present it at once can hold it", %{
      directory: directory
    } do
      {:ok, path} = issue(directory)
      {:ok, token} = BootstrapToken.read_token(path)

      opts = opts(directory)

      # The callers are released together, so that they present the token at
      # the same moment rather than one after another.
      parent = self()

      callers =
        for _ <- 1..32 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> BootstrapToken.verify_and_consume("workspace", token, opts)
            end
          end)
        end

      for _ <- callers do
        assert_receive({:ready, _})
      end

      Enum.each(callers, &send(&1.pid, :go))
      results = Enum.map(callers, &Task.await(&1, 30_000))

      spent = Enum.count(results, &(&1 == :ok))

      assert spent == 1,
             "#{spent} callers spent the token; a one-time token is spent once"

      for result <- results, result != :ok do
        assert {:error, _reason} = result
      end
    end

    test "a token that was claimed and not used is a token again", %{directory: directory} do
      {:ok, path} = issue(directory)
      {:ok, token} = BootstrapToken.read_token(path)

      opts = opts(directory)

      {:ok, claim} = BootstrapToken.claim("workspace", token, opts)
      assert :ok = BootstrapToken.release(claim, opts)

      # The token can be claimed again, and only once.
      assert {:ok, claim} = BootstrapToken.claim("workspace", token, opts)
      assert {:error, :bootstrap_token_refused} = BootstrapToken.claim("workspace", token, opts)

      # And it is spent when the work it authorised happened.
      assert :ok = BootstrapToken.spend(claim, opts)
      assert {:error, :no_token_for_workspace} = BootstrapToken.claim("workspace", token, opts)
    end

    test "a spent token leaves nothing readable behind", %{directory: directory} do
      {:ok, path} = issue(directory)
      {:ok, token} = BootstrapToken.read_token(path)

      assert :ok = BootstrapToken.verify_and_consume("workspace", token, opts(directory))

      # The delivery copy is emptied: a token that is spent and still on
      # disk is a token that can be presented again.
      assert {:error, :no_token_in_the_file} = BootstrapToken.read_token(path)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Issues a token into the directory, and returns the path it was written
  # to.
  defp issue(directory) do
    path = Path.join(directory, "token.secret")

    BootstrapToken.issue("workspace",
      path: path,
      record: Path.join(directory, "token.json")
    )
  end

  defp opts(directory) do
    [path: Path.join(directory, "token.secret"), record: Path.join(directory, "token.json")]
  end

  # Watches the directory while the secret is written.
  #
  # A file that another user can read **and** that holds something shaped
  # like the token is a secret that another user has. The scan is bounded by
  # the test: the watcher stops when the test is over.
  defp watch(directory, reporter) do
    for file <- Path.wildcard(Path.join(directory, "*")) do
      case {File.stat(file), File.read(file)} do
        {{:ok, %File.Stat{mode: mode}}, {:ok, contents}} ->
          if Bitwise.band(mode, 0o077) != 0 and secret?(contents) do
            send(reporter, {:exposed, file})
          end

        _other ->
          :ok
      end
    end

    send(reporter, {:scan, System.unique_integer([:positive])})

    receive do
      :stop -> :ok
    after
      1 -> watch(directory, reporter)
    end
  end

  # The token is 32 bytes of hexadecimal, and so is the digest recorded in
  # its place. Either of them in a file another user can read is a finding.
  defp secret?(contents), do: String.match?(contents, ~r/[0-9a-f]{64}/)
end
