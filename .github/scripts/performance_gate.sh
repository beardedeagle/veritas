#!/usr/bin/env bash
#
# The performance gate.
#
# It runs the benchmark harness and fails the build on a finding. It is the
# script the workflow calls, and it runs by hand from a clean checkout with
# no arguments.
#
# The store is the harness's own: the harness starts a SurrealDB of its own,
# on its own port, with its own data directory, and removes it afterwards.
# So the run does not depend on a store somebody else started, and it does
# not touch anybody's data.
#
# The harness's own tests run first. A harness that is broken should say so
# before it reports a breach, and a breach reported by a broken harness is
# worse than no report.
#
# Environment:
#
#   MODE      the gate to apply: `check` (the full gate) or
#             `check-deterministic` (the gates that do not depend on how
#             fast the machine is). Default: check-deterministic.
#   SAMPLES   samples per scenario. Default: 30.
#   REPORT    where the JSON report is written. Default: bench/last-run.json.

set -euo pipefail

MODE="${MODE:---check-deterministic}"
SAMPLES="${SAMPLES:-30}"
REPORT="${REPORT:-bench/last-run.json}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

export MIX_ENV=test
export SURREAL_BIN="${SURREAL_BIN:-/tmp/sdb/surreal}"

if [ ! -x "$SURREAL_BIN" ]; then
  echo "::error::no SurrealDB binary at $SURREAL_BIN. The workflow extracts one from the pinned image; see .github/workflows/performance.yml." >&2
  exit 2
fi

echo "== the harness's own tests =="
mix run --no-start bench/harness/test/run.exs

echo
echo "== the benchmark =="
mix veritas.bench "$MODE" --samples "$SAMPLES" --json "$REPORT"
