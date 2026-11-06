defmodule Veritas.Web.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Veritas.Web.Telemetry,
      # The PubSub server the endpoint and the LiveView machinery subscribe
      # through. Its name must match the endpoint's `pubsub_server:`.
      Veritas.Web.PubSub,
      # Start to serve requests, typically the last entry
      Veritas.Web.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Veritas.Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Veritas.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
