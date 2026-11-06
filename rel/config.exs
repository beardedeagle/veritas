defmodule Veritas.Release do
  @moduledoc """
  The shape of a Veritas release.

  A release is a **directory** that carries everything the node needs to
  run, including the datastore's own binary. The datastore is a separate
  process, not a NIF inside the BEAM (ADR-048): a NIF has to be built per
  target, breaks Alpine/musl, Windows and Nix, and couples the store's
  crash domain to the BEAM's. So the `surreal` binary is a **file** in the
  release — the same file on every platform, fetched, pinned and verified by
  `mix veritas.store.install`.

  ## Building it

      mix veritas.store.install    # the pinned, verified binary
      mix release                   # the release, with the binary in it

  The first command is not optional: the release bundles what it produced,
  and a release without the binary is a release that cannot start.
  """

  def config do
    [
      veritas: [
        # The datastore's binary is copied into the release by a step of our
        # own, declared with the release in `mix.exs`: the overlay mechanism
        # copies what is in `rel/overlays` **as it is**, and a symlink there
        # would be a symlink in the release. The binary lands at
        # `vendor/surreal/surreal`, the same relative path a checkout uses.

        # ERTS and the native libraries are shipped, so the host needs no
        # Erlang, no Elixir and no libc of a particular vintage.
        include_erts: true,
        include_executables_for: [:unix, :windows],

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
      ]
    ]
  end

end
