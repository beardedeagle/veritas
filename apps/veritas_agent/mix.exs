defmodule Veritas.Agent.MixProject do
  use Mix.Project

  def project do
    [
      app: :veritas_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: dialyzer_config(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {Veritas.Agent.Application, []}
    ]
  end

  defp deps do
    [
      # Dialyzer analyses one application at a time, so the gate runs
      # inside each application. It is not a runtime dependency of a
      # release.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:veritas_core, in_umbrella: true}
    ]
  end

  # The umbrella root's `setup` alias runs `mix setup` in every child
  # application, so every child has to have one. This application ships no
  # assets, so its setup is the dependencies and nothing else.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end

  # The Dialyzer configuration is shared by the whole product and lives in
  # the umbrella root, so there is one configuration and not four. Only the
  # two PLT file names differ per application: a PLT holds the modules of one
  # application, and the four applications cannot share a project PLT.
  defp dialyzer_config do
    Path.expand("../../.dialyzer.exs", __DIR__)
    |> Code.eval_file()
    |> elem(0)
    |> Keyword.merge(
      plt_core_path: Path.expand("../../_build/dialyzer/veritas_agent-core.plt", __DIR__),
      plt_local_path: Path.expand("../../_build/dialyzer/veritas_agent.plt", __DIR__)
    )
  end
end
