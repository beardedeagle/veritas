defmodule Veritas.Core.Dev.LauncherTest do
  @moduledoc """
  The launcher, proved where the command is read.

  The one thing this test exists for: **the command's own flags survive**.
  `mix veritas.launch bench mix veritas.bench --samples 5` has to pass
  `--samples 5` to the command, and the launcher's own switches belong before
  the label. A parser that does not know a switch would either refuse the
  command or swallow the switch and its value — and the command would run with
  the wrong arguments, or not at all.
  """
  use ExUnit.Case, async: false

  alias Veritas.Core.Test.FakeProcess

  setup do
    Application.put_env(:veritas_core, :process_adapter, FakeProcess)

    on_exit(fn ->
      Application.delete_env(:veritas_core, :process_adapter)
      Application.delete_env(:veritas_core, :fake_started)
    end)

    :ok
  end

  test "the command keeps its own flags, and the launcher's switches come first" do
    registry = registry_path()

    Mix.Tasks.Veritas.Launch.run([
      "--registry",
      registry,
      "bench",
      "mix",
      "veritas.bench",
      "--samples",
      "5"
    ])

    assert FakeProcess.started() == ["mix", "veritas.bench", "--samples", "5"]

    # The registry is what makes the process ours for the reaper, even when
    # it was started from somewhere else.
    assert File.read!(registry) =~ ~r/\tbench\t/
  end

  test "the switch may also be spelled --name=value" do
    registry = registry_path()

    Mix.Tasks.Veritas.Launch.run([
      "--registry=" <> registry,
      "bench",
      "mix",
      "veritas.bench"
    ])

    assert FakeProcess.started() == ["mix", "veritas.bench"]
    assert File.read!(registry) =~ ~r/\tbench\t/
  end

  test "the command is passed on verbatim, including a separator of its own" do
    registry = registry_path()

    Mix.Tasks.Veritas.Launch.run([
      "--registry",
      registry,
      "bench",
      "--",
      "--samples",
      "5"
    ])

    assert FakeProcess.started() == ["--", "--samples", "5"]
  end

  defp registry_path do
    # Under the checkout's `var/`, which is runtime state and is ignored: the
    # sandbox denies writes to some temporary directories.
    Path.join(
      Veritas.Dev.Process.project_root(),
      "var/launch-test-#{System.unique_integer([:positive])}.tsv"
    )
  end
end
