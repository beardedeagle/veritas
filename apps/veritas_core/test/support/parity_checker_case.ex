defmodule Veritas.Core.Test.ParityCheckerCase do
  @moduledoc """
  ExUnit event formatter for the independently specified parity proof cases.

  Emits observed test completion events, not claimed coverage totals. The
  checker must match identity, file, terminal state and suite completion.
  Excluded and skipped tests are never reported as passed. No manifest data
  is read by this formatter.
  """
  use GenServer

  @prefix "VERITAS_PARITY_EVENT "

  @doc "Starts the formatter with the options supplied by ExUnit."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init(_options), do: {:ok, 0}

  @impl GenServer
  def handle_cast({:test_finished, test}, state) do
    emit(%{
      "event" => "test_finished",
      "id" => test.tags[:parity_proof],
      "module" => inspect(test.module),
      "test" => Atom.to_string(test.name),
      "file" => test.tags[:file],
      "state" => terminal_state(test.state)
    })

    {:noreply, state + 1}
  end

  def handle_cast({:suite_finished, _timing}, state) do
    emit(%{"event" => "suite_finished", "tests" => state})
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp terminal_state(nil), do: "passed"
  defp terminal_state({:skipped, _}), do: "skipped"
  defp terminal_state({:excluded, _}), do: "excluded"
  defp terminal_state(_state), do: "failed"

  defp emit(event), do: IO.puts(@prefix <> Jason.encode!(event))
end
