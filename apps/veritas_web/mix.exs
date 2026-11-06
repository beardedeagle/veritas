defmodule Veritas.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :veritas_web,
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
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Veritas.Web.Application, []},
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
      {:absinthe, "~> 1.12"},
      {:absinthe_plug, "~> 1.5"},
      {:veritas_core, in_umbrella: true},
      {:veritas_agent, in_umbrella: true},
      {:veritas_plugin, in_umbrella: true},
      {:phoenix, "~> 1.8.16"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      # The HTTP server. The floor is the release that carries no open
      # advisory: 1.13.1 and every earlier 1.x are refused by the CVE gate
      # in `docs/09` §6.5, so they must not be resolvable at all.
      {:bandit, "~> 1.14"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind veritas_web", "esbuild veritas_web"],
      "assets.deploy": [
        "tailwind veritas_web --minify",
        "esbuild veritas_web --minify",
        "phx.digest"
      ]
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
      plt_core_path: Path.expand("../../_build/dialyzer/veritas_web-core.plt", __DIR__),
      plt_local_path: Path.expand("../../_build/dialyzer/veritas_web.plt", __DIR__)
    )
  end
end
