defmodule Veritas.MixProject do
  use Mix.Project

  def project do
    [
      app: :veritas_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: dialyzer_config(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Veritas.Core.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Dialyzer analyses one application at a time, so the gate runs
      # inside each application. It is not a runtime dependency of a
      # release.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Argon2id, the hash the corpus fixes for local passwords
      # (`docs/09` §3). Apache-2.0, no commercial tier.
      {:argon2_elixir, "~> 4.1"},
      # The approved replaceable IANA provider, pinned exactly. tz 0.28.4
      # bundles tzdata2026d.
      {:tz, "== 0.28.4"},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
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
      plt_core_path: Path.expand("../../_build/dialyzer/veritas_core-core.plt", __DIR__),
      plt_local_path: Path.expand("../../_build/dialyzer/veritas_core.plt", __DIR__)
    )
  end
end
