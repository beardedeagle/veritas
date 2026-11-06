defmodule Veritas.Plugin.Application do
  @moduledoc """
  Supervises the plugin host.

  Two children:

    * `Veritas.Plugin.Registry` — what is installed, and what is running;
    * `Veritas.Plugin.SessionSupervisor` — the Plugin sessions. Each Plugin
      is a separate OS process, and a session is the host's half of the
      conversation with it.

  The session supervisor is a `DynamicSupervisor` because Plugins come and
  go: installing one starts a session and uninstalling one ends it, and
  neither restarts the host.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Veritas.Plugin.Registry,
      {DynamicSupervisor, name: Veritas.Plugin.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Veritas.Plugin.Supervisor)
  end
end
