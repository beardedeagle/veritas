defmodule Veritas.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      # The release, as `docs/10` §Release Artifact Layout specifies it: one
      # release named `veritas`, carrying every application. Mix requires an
      # umbrella to name its releases and their starting points explicitly,
      # so this list is not optional. The three service roles the corpus
      # describes (server, scheduler, agent) are the same release with
      # different start flags, so every application is permanent.
      releases: [
        veritas: [
          include_executables_for: [:unix, :windows],
          # The datastore's binary travels with the release: it is a separate
          # process and not a NIF (ADR-048), so it is the same file on every
          # platform, and it is fetched, pinned and verified by
          # `mix veritas.store.install`. It reaches the release through
          # `rel/overlays`, which Mix always copies into the release root.
          applications: [
            veritas_core: :permanent,
            veritas_web: :permanent,
            veritas_plugin: :permanent,
            veritas_agent: :permanent
          ],
          # The datastore's binary is copied into the release by a step of our
          # own, because the overlay mechanism copies what is in
          # `rel/overlays` **as it is** — a symlink there would be a symlink in
          # the release, and a release has to carry the file.
          steps: [&clear_stale_overlays/1, :assemble, &copy_store/1, :tar]
        ]
      ],
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer_config(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # `rel/overlays` is copied into the release as it is, so a symlink left
  # there becomes a symlink in the release — or a broken one, if the checkout
  # it pointed at is not there. The datastore's binary is copied in by a step
  # of our own instead, so the overlay directory is cleared first.
  #
  # A step returns the release it was given: that is what Mix expects, and
  # a step that returns anything else stops the build.
  defp clear_stale_overlays(release) do
    stale = Path.join(File.cwd!(), "rel/overlays/vendor")

    if File.exists?(stale) do
      _ = File.rm_rf(stale)
    end

    release
  end

  # The datastore's binary, copied into the release as a real file.
  #
  # It is fetched, pinned and verified by `mix veritas.store.install`, and it
  # is the same file on every platform: the datastore is a separate process
  # and not a NIF (ADR-048).
  defp copy_store(release) do
    source = Path.join(File.cwd!(), "vendor/surreal")
    target = Path.join(release.path, "vendor/surreal")

    unless File.dir?(source) do
      Mix.raise("""
      the release has no datastore binary.

        #{source} does not exist.

      Run `mix veritas.store.install` before `mix release`: the release
      bundles the datastore's binary, and a release without it is a release
      that cannot start.
      """)
    end

    File.mkdir_p!(target)

    # Whatever is there is replaced, so the release always carries the
    # binary that was pinned and not a leftover.
    for name <- File.ls!(source) do
      path = Path.join(target, name)
      File.rm(path)
      File.cp!(Path.join(source, name), path)
    end

    # The datastore's binary is named for the platform it runs on: the
    # installer writes `surreal.exe` on Windows. A step that assumed the
    # name `surreal` aborted the Windows build on a file that is not there.
    binary = Path.join(target, store_binary_name())

    if File.exists?(binary) do
      File.chmod!(binary, 0o755)
    end

    %{release | overlays: release.overlays ++ ["vendor/surreal"]}
  end

  # The datastore's binary's name, for the platform this release is built
  # for. The installer and the release have to agree on it.
  defp store_binary_name do
    case :os.type() do
      {:win32, _} -> "surreal.exe"
      _ -> "surreal"
    end
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # The static-analysis gates. They sit on the umbrella root because they
      # gate the whole product, not one application. `runtime: false` keeps
      # them out of a release: a release carries no analyser.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      # The gates. One alias per gate, so the CI workflow and a laptop run the
      # same command and the two cannot drift apart. `precommit` is the
      # umbrella's entry point into them.
      #
      # The stock list was
      #   ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
      # and it changed for three reasons:
      #   * `format` *rewrites* files, so it cannot be a gate. `format
      #     --check-formatted` fails instead of fixing, and the fix stays a
      #     separate, explicit `mix format`.
      #   * `deps.unlock --unused` is the deprecated spelling of
      #     `--check-unused`; the new spelling is what fails the build.
      #   * the two static analysers were missing, so nothing caught a
      #     consistency or type error before it reached a reviewer.
      precommit: [
        "ci.toolchain",
        "ci.compile",
        "ci.deps",
        "ci.format",
        "ci.lint",
        "ci.secrets",
        "ci.types",
        "ci.test"
      ],
      # The toolchain drift check: what is running against what
      # `.tool-versions` pins. A build on a different toolchain is a
      # different build.
      "ci.toolchain": ["veritas.toolchain"],
      "ci.compile": ["compile --warnings-as-errors"],
      "ci.deps": ["deps.unlock --check-unused"],
      "ci.format": ["format --check-formatted"],
      # Credo is the consistency analyser. It was named by `precommit` and by
      # the CI workflow, and the alias that gave it a name was missing — so
      # `mix precommit` and the lint job both failed on an unknown task
      # rather than on a lint finding.
      "ci.lint": ["credo --strict"],
      # The secret scan: the whole git history, and a built artefact when
      # one is given.
      "ci.secrets": ["veritas.secrets"],
      # Dialyzer analyses one application at a time, so it runs in every
      # child app rather than at the umbrella root.
      "ci.types": ["cmd mix dialyzer"],
      "ci.test": ["test"]
    ]
  end

  # The Dialyzer configuration is shared by the whole product and lives in
  # the umbrella root, so there is one configuration and not five. Only the
  # two PLT file names differ per application: a PLT holds the modules of one
  # application, and the applications cannot share a project PLT.
  defp dialyzer_config do
    Path.expand(".dialyzer.exs", __DIR__)
    |> Code.eval_file()
    |> elem(0)
    |> Keyword.merge(
      plt_core_path: Path.expand("_build/dialyzer/umbrella-core.plt", __DIR__),
      plt_local_path: Path.expand("_build/dialyzer/umbrella.plt", __DIR__)
    )
  end
end
