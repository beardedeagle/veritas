defmodule Veritas.Core.Dev.ProcessUnixScriptTest do
  @moduledoc """
  The shell script the Unix launcher runs, proved as a string.

  The launcher builds a **shell script** — it is the only way on this platform
  to start a process that outlives the caller, print its pid and write to a
  log in one step. A shell script is a place where an argument can be read as
  something other than an argument, so the quoting is the thing that matters
  here: an argument with a space must stay one word, and an argument with a
  `;` must not start a second command.

  These are string facts, so they are proved on every platform the suite runs
  on — Windows included, where this script is never used.
  """
  use ExUnit.Case, async: true

  alias Veritas.Dev.Process.Unix

  test "an argument with a space stays one word" do
    script = Unix.launch_script(["elixir", "-e", "Process.sleep(:infinity)"], "/tmp/log")

    assert script =~ "'Process.sleep(:infinity)'"
  end

  test "an argument cannot end the command and start another one" do
    script = Unix.launch_script(["bench", "; rm -rf /"], "/tmp/log")

    # The whole argument is one quoted word, so the `;` is a character in it
    # and not a separator between two commands.
    assert script =~ "'; rm -rf /'"
    refute script =~ "bench ; rm -rf /"
  end

  test "a single quote in an argument cannot close the quoting" do
    script = Unix.launch_script(["bench", "it's here"], "/tmp/log")

    # The quote is closed, escaped and opened again: 'it'\''s here'
    assert script =~ "'it'\\''s here'"
  end

  test "the log is quoted too, and the pid is printed" do
    script = Unix.launch_script(["bench"], "/var/log/with space/bench.log")

    assert script =~ "'/var/log/with space/bench.log'"
    assert script =~ "echo $!"
  end
end
