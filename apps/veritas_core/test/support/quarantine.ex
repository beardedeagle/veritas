defmodule Veritas.Core.Test.Quarantine do
  @moduledoc """
  The registry of known failures and policy exceptions.

  `docs/12` §Flakiness and Quarantine Policy sets the rules: a quarantined
  test needs an issue, a named owner, a written reason and an expiry date; the
  expiry is 14 days; a permanent skip is not allowed. This module is where
  those facts live, and `veritas_core/flakiness_test.exs` is what holds the
  suite to them.

  Two kinds of entry:

    * **known failure** — a defect that has been found and not yet fixed. The
      evidence is named, so the next engineer can check it rather than
      rediscover it.

    * **policy exception** — a deliberate departure from a rule the suite
      enforces mechanically. The one today is a bounded readiness wait in the
      integration harness, which is not a synchronisation sleep: it waits for
      a process to be *up*, with a deadline, and it is the only wait in the
      suite.

  Every entry expires. An expired entry is a failure of the flakiness test,
  not a silent pass: the thing it was covering either got fixed or got
  quietly forgotten.
  """

  @known_failures [
    %{
      id: "store/surrealdb-engine-fault-on-a-ticket-write",
      kind: :known_risk,
      reason:
        "SurrealDB 3.3.4 answers a ticket write with \"The database encountered " <>
          "unreachable logic: surrealdb/core/src/doc/document.rs:1147: Expected a " <>
          "document id to be present\" — an engine fault in its own write path, " <>
          "not a domain refusal. The cause is the shape the corpus prescribes: " <>
          "`docs/07` says `DEFINE FIELD id ON ticket TYPE string`, and the Adapter " <>
          "addresses the row as `ticket:<ulid>` and writes `id = '<the same " <>
          "ulid>'`. With a declared `id` field the engine requires that field to " <>
          "*be* the record id, and 3.3.4 loses the record id there: the same value " <>
          "panics, a different value is refused with \"a specified record id " <>
          "exists\". It reproduces in six lines. The corpus must choose — drop the " <>
          "`id` field and let the Adapter restore the logical id on read, or state " <>
          "it as `record<table>` — and the Adapter follows; `docs/32` §Record " <>
          "identity makes the physical id the Adapter's business. The property " <>
          "harness tells a store fault from a domain refusal and re-evaluates the " <>
          "case, printing the re-evaluation, so the fault cannot masquerade as a " <>
          "counterexample and cannot hide either.",
      owner: "SDET with the BEAM Engineer",
      issue:
        "BEAM Engineer, with the corpus owner — docs/07's `id` field and the store Adapter's write shape",
      expires: ~D[2026-11-10]
    },
    %{
      id: "store/the-managed-store-publishes-its-url-globally",
      kind: :known_risk,
      reason:
        "`Veritas.Store.Surreal.Server` publishes the managed store's URL into " <>
          "the application environment when it starts, and the Adapter reads " <>
          "that environment on every request. So a test that starts a store " <>
          "of its own redirects every other test in the run for as long as it " <>
          "holds, and a redirected test reads a different transition table and " <>
          "a different Audit Log — which looks like a property that is wrong, " <>
          "and which is how the SRE's two property failures looked. The suite " <>
          "now puts its own store configuration back before each test and " <>
          "before each property case, so the exposure is closed on this side; " <>
          "the seam that removes it — the Adapter resolving its store through " <>
          "the supervision tree rather than through a mutable global — is a " <>
          "product change and is with the BEAM Engineer.",
      owner: "SDET with the BEAM Engineer",
      issue:
        "BEAM Engineer — Veritas.Store.Surreal.Server publishing into the application environment",
      expires: ~D[2026-11-10]
    },
    %{
      id: "search-hit-shape/diverges-between-adapters",
      kind: :known_risk,
      reason:
        "The two implementations of the store contract return different search " <>
          "hits. The shipped SurrealDB adapter returns `id`, `subject`, " <>
          "`chunk_index`, `content` and `score`; the in-memory adapter returns " <>
          "the chunk as it was stored plus `score`, so it carries no `subject` " <>
          "and no `chunk_index`. A consumer that reads `hit[\"subject\"]` works " <>
          "against one store and breaks against the other, which is exactly the " <>
          "substitutability the contract promises. `docs/32` O-10 names the hit " <>
          "shape, and the conformance suite checks the part both adapters agree " <>
          "on (a score, and a stable order) rather than pretending the shapes " <>
          "match.",
      owner: "SDET with the BEAM Engineer",
      issue: "docs/32 §The contract document (O-10)",
      expires: ~D[2026-11-08]
    },
    %{
      id: "search-hit-shape/no-highlights",
      kind: :known_risk,
      reason:
        "`docs/32` O-11 says full-text search returns highlights. Neither " <>
          "adapter returns them: both return the matched chunk and a score. " <>
          "The conformance suite therefore checks the ranking obligations — " <>
          "stable order for a fixed corpus, and a non-empty result for a " <>
          "matching query — and the highlight requirement is recorded here " <>
          "rather than being quietly dropped.",
      owner: "SDET with the BEAM Engineer",
      issue: "docs/32 §The contract document (O-11)",
      expires: ~D[2026-11-08]
    }
  ]

  @policy_exceptions [
    %{
      id: "apps/veritas_core/test/mix/tasks/veritas_parity_check_test.exs",
      kind: :policy_exception,
      reason:
        "The embedded proof fixture deliberately blocks forever so the executor " <>
          "must enforce its timeout and stop the independently observed child. " <>
          "Readiness polls the child's private ping response against a monotonic " <>
          "deadline. No product assertion waits for a guessed settling duration.",
      owner: "SDET with Codex",
      issue: "VERITAS-INSTRUMENT-2026-11-04 timeout and child-cleanup controls",
      expires: ~D[2026-11-19]
    },
    %{
      id: "apps/veritas_core/test/veritas_core/parity_executor_test.exs",
      kind: :policy_exception,
      reason:
        "Fixture processes deliberately remain alive to challenge timeout and " <>
          "caller-cancellation cleanup. Bounded readiness and closure polls " <>
          "observe private listener state with a monotonic deadline; an " <>
          "independent stop channel tears down even a failed control.",
      owner: "SDET with Codex",
      issue: "VERITAS-INSTRUMENT-2026-11-04 worker lifecycle qualification",
      expires: ~D[2026-11-19]
    },
    %{
      id: "apps/veritas_core/test/support/surreal_server.ex",
      kind: :policy_exception,
      reason:
        "The integration harness waits for the SurrealDB it started to answer " <>
          "/health before the tests run. The wait is bounded by a deadline, it " <>
          "waits for a process to be up rather than for the product to catch up, " <>
          "and it is the only wait in the suite. Everything else is synchronised " <>
          "on observable state.",
      owner: "SDET",
      issue: "docs/12 §Flakiness and Quarantine Policy",
      expires: ~D[2026-11-08]
    },
    %{
      id: "apps/veritas_core/test/veritas/store/surreal/server_test.exs",
      kind: :policy_exception,
      reason:
        "The test waits for the store the supervised child starts to answer " <>
          "/health, and for the supervisor to start it again after it has been " <>
          "killed. Both waits are bounded by a deadline, and both wait for a " <>
          "process to be up rather than for the product to catch up.",
      owner: "SRE",
      issue: "docs/12 §Flakiness and Quarantine Policy",
      expires: ~D[2026-11-08]
    },
    %{
      id: "apps/veritas_core/test/veritas_core/dev_process_unix_script_test.exs",
      kind: :policy_exception,
      reason:
        "The file names `Process.sleep` inside a string it asserts on — it " <>
          "builds a launch script and checks what the script says — and it does " <>
          "not sleep. The flakiness scanner reads a file's text rather than its " <>
          "code, so the name is read as a wait. The scanner is the thing to " <>
          "change; until it is, this file is registered so that the rule stays " <>
          "green and says what it means.",
      owner: "SRE, with the process-policy owner",
      issue: "the flakiness scanner reads text, not code — Veritas.Core.FlakinessTest",
      expires: ~D[2026-11-08]
    },
    %{
      id: "apps/veritas_core/test/veritas_core/chain_key_test.exs",
      kind: :policy_exception,
      reason:
        "The test races two operating system processes against one another to " <>
          "publish the chain key ring, and each of them has to be up before " <>
          "either is released. The waits are bounded by a deadline, and they wait " <>
          "for a process to be up rather than for the product to catch up: the " <>
          "test waits for the two writers to signal that they are running, and " <>
          "the writers wait for the file that releases them. Nothing here waits " <>
          "for the product to settle.",
      owner: "Mavis, acting as SDET for the security remediation",
      issue: "docs/12 §Flakiness and Quarantine Policy",
      expires: ~D[2026-11-08]
    }
  ]

  @doc "The known failures and known risks."
  def known_failures, do: @known_failures

  @doc "The deliberate departures from the mechanically enforced rules."
  def policy_exceptions, do: @policy_exceptions

  @doc "Every entry, of either kind."
  def entries, do: @known_failures ++ @policy_exceptions

  @doc "Whether an entry has expired on the given date."
  def expired?(%{expires: expires}, today) do
    Date.compare(expires, today) == :lt
  end

  @doc """
  The test files that are allowed to use a blocking wait.

  The key is a substring of the file's path, so a file can be allowed without
  naming it twice.
  """
  def allowed_wait_files, do: Enum.map(@policy_exceptions, & &1.id)
end
