defmodule Veritas.Core.Dev.PlatformSeamsTest do
  @moduledoc """
  The platform seams, proved as contracts.

  Two platform differences reach the product's own code: the **terminal** a
  secret is read from, and the **clipboard** a token is copied to. Both are
  behind a named seam so the caller names the contract rather than the tool,
  and both are substitutable — which is what makes them testable without a
  host that has the tool.
  """
  use ExUnit.Case, async: false

  defmodule FakeTerminal do
    @moduledoc false
    @behaviour Veritas.Dev.Terminal

    @impl Veritas.Dev.Terminal
    def masked_read(_prompt), do: {:error, :no_terminal}

    @impl Veritas.Dev.Terminal
    def read_line, do: {:error, :eof}
  end

  defmodule FakeClipboard do
    @moduledoc false
    @behaviour Veritas.Dev.Clipboard

    @impl Veritas.Dev.Clipboard
    def copy(_text), do: {:error, :clipboard_unavailable}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:veritas_core, :terminal_adapter)
      Application.delete_env(:veritas_core, :clipboard_adapter)
    end)

    :ok
  end

  test "the terminal seam forwards to its implementation and keeps the refusal" do
    Application.put_env(:veritas_core, :terminal_adapter, FakeTerminal)

    # The refusal is the contract: a masked-looking read that still echoes is
    # worse than no read at all.
    assert Veritas.Dev.Terminal.masked_read("bootstrap token: ") == {:error, :no_terminal}
  end

  test "the clipboard seam forwards to its implementation and keeps the refusal" do
    Application.put_env(:veritas_core, :clipboard_adapter, FakeClipboard)

    # The clipboard is a convenience, not a channel of record, and a host
    # without one says so rather than claiming to have copied.
    assert Veritas.Dev.Clipboard.copy("a token") == {:error, :clipboard_unavailable}
  end

  describe "the native clipboard adapter" do
    setup do
      directory =
        Path.join(
          System.tmp_dir!(),
          "clipboard fixture & %VALUE% ! $-#{System.unique_integer([:positive])}"
        )

      bin = Path.join(directory, "bin")
      File.mkdir_p!(bin)
      previous = Map.new(["PATH", "TMPDIR", "TEMP", "TMP"], &{&1, System.get_env(&1)})
      System.put_env("PATH", bin)
      System.put_env("TMPDIR", directory)
      System.put_env("TEMP", directory)
      System.put_env("TMP", directory)

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        File.rm_rf!(directory)
      end)

      %{directory: directory, bin: bin}
    end

    for {command, arguments} <- [
          {"pbcopy", []},
          {"clip.exe", []},
          {"xclip", ["-selection", "clipboard"]},
          {"wl-copy", []}
        ] do
      @tag skip: match?({:win32, _}, :os.type())
      test "#{command} receives exact bytes through stdin", context do
        command = unquote(command)
        fixture(context, command, 0)
        text = "harmless '$HOME' \"; & %PATH% café\nsecond line\n" <> <<0, 255>>

        assert ExUnit.CaptureIO.capture_io(fn ->
                 assert Veritas.Dev.Clipboard.System.copy(text) == :ok
               end) == ""

        assert File.read!(Path.join(context.directory, command <> ".bytes")) == text

        assert File.read!(Path.join(context.directory, command <> ".args")) ==
                 Enum.join(unquote(arguments), " ")

        assert String.trim(File.read!(Path.join(context.directory, command <> ".mode"))) == "600"

        assert String.trim(File.read!(Path.join(context.directory, command <> ".directory-mode"))) ==
                 "700"

        assert Path.wildcard(Path.join(context.directory, "veritas-clipboard-*")) == []
      end
    end

    @tag skip: match?({:win32, _}, :os.type())
    test "a nonzero exit refuses and removes the private input", context do
      fixture(context, "pbcopy", 7)

      assert Veritas.Dev.Clipboard.System.copy("harmless failure") ==
               {:error, :clipboard_unavailable}

      assert File.read!(Path.join(context.directory, "pbcopy.bytes")) == "harmless failure"
      assert Path.wildcard(Path.join(context.directory, "veritas-clipboard-*")) == []
    end

    @tag skip: match?({:win32, _}, :os.type())
    test "a failing candidate falls through to the next tool", context do
      fixture(context, "pbcopy", 7)
      fixture(context, "wl-copy", 0)
      assert Veritas.Dev.Clipboard.System.copy("harmless fallback") == :ok
      assert File.read!(Path.join(context.directory, "wl-copy.bytes")) == "harmless fallback"
    end

    @tag skip: match?({:win32, _}, :os.type())
    test "empty and large inputs reach EOF without alteration", context do
      fixture(context, "pbcopy", 0)

      for text <- ["", String.duplicate("harmless\n", 20_000)] do
        assert Veritas.Dev.Clipboard.System.copy(text) == :ok
        assert File.read!(Path.join(context.directory, "pbcopy.bytes")) == text
      end
    end

    @tag skip: match?({:win32, _}, :os.type())
    test "a background selection owner cannot hold the caller's output pipe", context do
      path = Path.join(context.bin, "pbcopy")

      File.write!(path, """
      #!/bin/sh
      /bin/cat > /dev/null
      (/bin/sleep 2) &
      exit 0
      """)

      File.chmod!(path, 0o700)
      task = Task.async(fn -> Veritas.Dev.Clipboard.System.copy("harmless background probe") end)
      result = Task.yield(task, 1_000)
      if is_nil(result), do: Task.await(task, 5_000)

      assert result == {:ok, :ok}
      assert Path.wildcard(Path.join(context.directory, "veritas-clipboard-*")) == []
    end

    test "no tool means an explicit refusal", context do
      assert Veritas.Dev.Clipboard.System.copy("harmless no-tool probe") ==
               {:error, :clipboard_unavailable}

      assert Path.wildcard(Path.join(context.directory, "veritas-clipboard-*")) == []
    end
  end

  # Only fixture executables are on PATH; no test can reach the owner's clipboard.
  defp fixture(context, command, status) do
    path = Path.join(context.bin, command)
    destination = Path.join(context.directory, command)

    stat =
      if :os.type() == {:unix, :darwin}, do: "/usr/bin/stat -Lf %Lp", else: "/usr/bin/stat -Lc %a"

    File.write!(path, """
    #!/bin/sh
    /bin/cat > '#{destination}.bytes'
    printf '%s' "$*" > '#{destination}.args'
    #{stat} "$VERITAS_CLIPBOARD_INPUT" > '#{destination}.mode'
    #{stat} "${VERITAS_CLIPBOARD_INPUT%/*}" > '#{destination}.directory-mode'
    /bin/cat "$VERITAS_CLIPBOARD_INPUT"
    /bin/cat "$VERITAS_CLIPBOARD_INPUT" >&2
    exit #{status}
    """)

    File.chmod!(path, 0o700)
  end
end
