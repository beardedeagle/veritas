defmodule Veritas.Dev.Clipboard do
  @moduledoc """
  Putting text on the system clipboard.

  The clipboard is a **convenience, not a channel of record**: every process
  the user runs can read it, so a token on the clipboard is a token on the
  clipboard. What the contract fixes is the failure: when no clipboard is
  available, the copy is **refused** — `{:error, :clipboard_unavailable}` —
  and the caller says so. It never claims to have copied what it did not.

  ## The platform differs; the contract does not

  macOS has `pbcopy`, Windows has `clip.exe`, and Linux has `xclip` (X11) or
  `wl-copy` (Wayland). The implementation tries them in turn, and the port
  (`Veritas.Dev.Process`) is the pattern: the platform specifics live in
  one adapter, and the caller names the contract rather than the tool.
  """

  @doc """
  Puts the text on the clipboard, or refuses.
  """
  @callback copy(text :: String.t()) :: :ok | {:error, :clipboard_unavailable}

  @doc """
  The implementation in force.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:veritas_core, :clipboard_adapter) || Veritas.Dev.Clipboard.System
  end

  @doc """
  Puts the text on the clipboard, or refuses.
  """
  @spec copy(String.t()) :: :ok | {:error, :clipboard_unavailable}
  def copy(text), do: adapter().copy(text)
end
