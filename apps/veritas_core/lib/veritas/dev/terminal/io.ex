defmodule Veritas.Dev.Terminal.Io do
  @moduledoc """
  The masked read, through Erlang's own io device.

  `:io.getopts/1` says whether the standard input is a terminal, and
  `:io.setopts/2` switches that terminal's echo off and on again. Neither
  needs a shell, so the read behaves the same on every platform the BEAM
  runs on.

  ## A pipe is not a terminal

  A pipe has no echo to switch off — nothing is echoed back — so a line
  read from it is read plainly. Only a terminal has an echo to mask, and
  only a terminal that refuses to mask it is refused.
  """

  @behaviour Veritas.Dev.Terminal

  @impl Veritas.Dev.Terminal
  def masked_read(prompt) do
    case terminal?() do
      false ->
        {:error, :no_terminal}

      true ->
        case :io.setopts(:standard_io, echo: false) do
          :ok ->
            try do
              read(prompt)
            after
              :io.setopts(:standard_io, echo: true)
            end

          {:error, _reason} ->
            {:error, :no_terminal}
        end
    end
  end

  @impl Veritas.Dev.Terminal
  def read_line do
    case terminal?() do
      false ->
        read("")

      true ->
        case :io.setopts(:standard_io, echo: false) do
          :ok ->
            try do
              read("")
            after
              :io.setopts(:standard_io, echo: true)
            end

          {:error, _reason} ->
            # The terminal will not be masked, and the token would show on the
            # screen. The read still happens: refusing to read a token that is
            # already on its way would fail the operator for no gain.
            read("")
        end
    end
  end

  defp terminal? do
    :io.getopts(:standard_io)[:terminal] == true
  end

  defp read(prompt) do
    IO.write(prompt)

    case IO.gets("") do
      :eof -> {:error, :eof}
      line -> {:ok, String.trim(line)}
    end
  end
end
