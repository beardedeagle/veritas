# Dialyzer configuration for Veritas.
#
# This file is the single configuration for the whole product. The umbrella
# root and every application load it (each application's mix.exs evaluates
# it and merges in its own two PLT file names, because a PLT holds the
# modules of one application and the four applications cannot share a
# project PLT).
#
# A cold PLT takes minutes to build. Both PLTs therefore live under the
# umbrella's shared _build directory, and CI caches them by mix.lock and the
# toolchain version, so only the first run after a dependency change pays
# for them.
#
# Two knobs the prompt for this file mentions, and where they actually live:
#
#   * the timeout — dialyxir 1.4.8 has no timeout option (its source has no
#     `:timeout` key), so the bound is enforced where a timeout can be
#     enforced: `timeout-minutes` on the CI job, which kills a PLT build
#     that has stopped making progress instead of letting it hang.
#
#   * the warning count that fails the build — dialyxir has no
#     `max_warnings` option either. Its behaviour is to exit non-zero on
#     the first warning, so the budget is zero warnings and the gate is
#     `mix dialyzer`. An acknowledged warning belongs in `ignore_warnings`
#     below, where it carries the reason it is accepted.
[
  # The core PLT holds OTP and the dependencies of the application.
  plt_core_path: Path.expand("_build/dialyzer/core.plt", __DIR__),

  # The project PLT holds the application itself.
  plt_local_path: Path.expand("_build/dialyzer/project.plt", __DIR__),

  # Dependencies belong in the PLT rather than in the analysis, so a
  # warning is always about our code and never about a dependency.
  plt_add_deps: :app_tree,

  # Dialyzer's own analysis flags. The defaults are kept: the corpus makes
  # the Adapter contract the thing the rest of the system may rely on, and
  # the flags that would enforce a contract are contract flags
  # (`:specdiffs`, `:unmatched_returns`), not general-purpose strictness.
  # They are a separate decision, taken with the BEAM Engineer against the
  # Adapter's own spec, not silently bolted on here.
  flags: [],

  # Warnings we accept, each with the reason it is accepted. Empty on
  # purpose: a warning that is acknowledged without a reason is a warning
  # nobody reads.
  ignore_warnings: []
]
