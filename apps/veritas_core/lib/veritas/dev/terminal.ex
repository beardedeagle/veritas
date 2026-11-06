defmodule Veritas.Dev.Terminal do
  @moduledoc """
  Reading a secret from a terminal, without a POSIX shell.

  The bootstrap token is a **credential**, and the path that reads it must
  work on every platform the product runs on. A `sh` and an `stty` do not
  exist on Windows, so a masked prompt written with them is a prompt that
  only exists on some of the product's platforms.

  ## The contract

    * `masked_read/1` writes a prompt and reads a line with the terminal's
      echo switched off. It **refuses** — `{:error, :no_terminal}` — when
      the input is not a terminal, because a masked-looking read that still
      echoes is worse than no read at all: it looks safe.
    * `read_line/0` reads a line with no prompt, for a token that arrives on
      standard input. The echo is switched off when the input is a terminal
      and the input is a pipe, so nothing echoes and the read is plain.

  ## What the implementation may use

  Erlang's own io device — `:io.getopts/1` and `:io.setopts/2` — which is
  on every platform the BEAM is, and needs no shell. The adapter is
  selected at run time, so a platform that needs a different mechanism
  substitutes one behind this contract rather than changing the caller.
  """

  @typedoc """
  The result of a masked read.

  `:no_terminal` means the input is not a terminal, so nothing can be
  masked; `:eof` means the input ended before a line arrived.
  """
  @type read_result :: {:ok, String.t()} | {:error, :no_terminal} | {:error, :eof}

  @doc """
  Reads one line with the echo off, after writing the prompt.
  """
  @callback masked_read(prompt :: String.t()) :: read_result()

  @doc """
  Reads one line with no prompt, masking the echo where there is one.
  """
  @callback read_line() :: read_result()

  @doc """
  The implementation in force.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:veritas_core, :terminal_adapter) || Veritas.Dev.Terminal.Io
  end

  @doc """
  Reads one line with the echo off, after writing the prompt.
  """
  @spec masked_read(String.t()) :: read_result()
  def masked_read(prompt), do: adapter().masked_read(prompt)

  @doc """
  Reads one line with no prompt, masking the echo where there is one.
  """
  @spec read_line() :: read_result()
  def read_line, do: adapter().read_line()
end
