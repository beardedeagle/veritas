#!/usr/bin/env bash
# Check that every third-party action is pinned to a commit SHA.
#
# A tag can be moved: `uses: owner/action@v1` is a promise about whatever
# the tag points at when the job starts, not about a particular piece of
# code. A commit SHA is a promise about one piece of code, forever. The
# third-party actions are the ones that matter — an action that is not
# GitHub's own is code this project chose to run, and it runs with the
# workflow's permissions.
#
# GitHub's own `actions/*` are exempt: they are published by the platform
# that runs them, and pinning them is a different decision from pinning a
# third party.
#
# The exceptions below are the actions that are still on a tag. Each one
# names the file it is in and the SHA to pin it to, so the remaining work
# is one edit away. An exception that is no longer needed is a failure:
# the list has to shrink to nothing.
#
# The list is empty: every third-party action is pinned.
#
# usage: check-action-pins.sh [workflow ...]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

# file|action@revision|sha-to-pin-it-to
exceptions="
"

sha_pattern='^[0-9a-f]{40}$'

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
fi

offenders=()
used_exceptions=()

for file in "${files[@]}"; do
  [ -f "$file" ] || continue

  while IFS= read -r line; do
    ref="${line#*uses: }"
    ref="${ref%%#*}"
    ref="$(printf '%s' "$ref" | tr -d '[:space:]')"

    case "$ref" in
      ""|./*|docker://*) continue ;;
    esac

    case "$ref" in
      *@*) ;;
      *) continue ;;
    esac

    owner="${ref%%/*}"
    revision="${ref##*@}"

    # GitHub's own actions are published by the platform that runs them.
    [ "$owner" = "actions" ] && continue

    if printf '%s' "$revision" | grep -qE "$sha_pattern"; then
      continue
    fi

    allowed=0
    for exception in $exceptions; do
      exception_file="${exception%%|*}"
      exception_rest="${exception#*|}"
      exception_ref="${exception_rest%%|*}"
      exception_sha="${exception_rest##*|}"

      if [ "$exception_file" = "$file" ] && [ "$exception_ref" = "$ref" ]; then
        allowed=1
        used_exceptions+=("$exception")
        break
      fi
    done

    if [ "$allowed" -eq 1 ]; then
      continue
    fi

    offenders+=("$file: $ref")
  done < <(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "$file" || true)
done

stale=()
for exception in $exceptions; do
  exception_file="${exception%%|*}"

  # An exception for a file that was not scanned is not stale: it is simply
  # not this run's business.
  scanned=0
  for file in "${files[@]}"; do
    [ "$file" = "$exception_file" ] && scanned=1
  done
  [ "$scanned" -eq 1 ] || continue

  found=0
  for used in "${used_exceptions[@]:-}"; do
    [ "$used" = "$exception" ] && found=1
  done
  [ "$found" -eq 0 ] && stale+=("$exception")
done

if [ "${#offenders[@]}" -gt 0 ] || [ "${#stale[@]}" -gt 0 ]; then
  echo "the third-party actions are not all pinned to a commit SHA." >&2
  echo >&2

  for offender in "${offenders[@]}"; do
    echo "  unpinned: $offender" >&2
  done

  for exception in "${stale[@]}"; do
    echo "  stale exception (the action is pinned now, or is gone): $exception" >&2
  done

  echo >&2
  echo "Pin an action to the commit SHA its tag resolves to, and keep the" >&2
  echo "version as a trailing comment:" >&2
  echo >&2
  echo "    - uses: owner/action@<40-hex-sha> # v1.2.3" >&2
  echo >&2
  echo "The SHA is found with:" >&2
  echo >&2
  echo "    git ls-remote https://github.com/owner/action.git 'refs/tags/v1' 'refs/tags/v1^{}'" >&2
  exit 1
fi

echo "every third-party action is pinned to a commit SHA"
