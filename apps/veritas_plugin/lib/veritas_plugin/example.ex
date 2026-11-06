defmodule Veritas.Plugin.Example do
  @moduledoc """
  The host's own example Plugin — a real program, started like any other.

  `docs/20` §Transport describes a Plugin as a separate OS process speaking
  JSON-RPC over a socket, and this host ships one so that description is
  demonstrable rather than aspirational: `priv/veritas-example` is a
  launcher and `priv/veritas_example.exs` is the program it starts. The
  example is started through the same path as any other Plugin — spawned,
  handshaked, granted capabilities, called over a socket.

  ## Why the host falls back to its own example

  A manifest names a **command**. The host resolves that command on `PATH`.
  When the command is not there, the host has two honest choices: refuse to
  start, or start something else. It refuses — except for one case: the
  command is **this host's own example**, in which case the host starts its
  own example.

  The distinction matters. A missing command for a real Plugin means the
  Plugin is not installed properly, and quietly starting something else
  would mask a broken install behind a working session. The example is the
  host's own artefact, so there is nothing to mask.

  The example is a **Default**: it is the shipped plugin of the plugin
  host, and a deployment may point the manifest at a real plugin instead.
  """

  @command "veritas-example"

  @doc "The command name the example answers to."
  @spec command() :: String.t()
  def command, do: @command

  @doc """
  The path of the shipped launcher.
  """
  @spec launcher() :: String.t()
  def launcher do
    Path.join(Application.app_dir(:veritas_plugin, "priv"), @command)
  end

  @doc """
  The Elixir runtime the example is started with.

  The example is an Elixir program, and the Plugin process is started with
  an **empty environment** — that is the boundary, and an inherited
  environment would hand the Plugin whatever the host happened to be holding
  — so the runtime has to be named explicitly.
  """
  @spec runtime() :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def runtime do
    with elixir when is_binary(elixir) <- System.find_executable("elixir"),
         erl when is_binary(erl) <- System.find_executable("erl") do
      {:ok, elixir, erl}
    else
      _ ->
        {:error,
         "no Elixir runtime is on PATH, so the host's example Plugin cannot be started"}
    end
  end
end
