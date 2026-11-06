#!/usr/bin/env bash
# Package the release that `mix release` produced, and checksum it.
#
# The release directory is _build/prod/rel/<release name>; the release name
# is the key of the `releases:` list in the umbrella root's mix.exs.
#
# The artifact is the release as it stands — ERTS, the BEAM, every
# application and every dependency — plus the operator's files: the service
# templates, the installer and the runbook, which the installer reads from
# the release home's `ops` directory.
#
# The archive is reproducible: the same input produces the same bytes on the
# same platform. Three things make that true, and all three are done here
# rather than left to the tar on the machine:
#
#   * the members are listed in one order, sorted by name, so the order does
#     not depend on the order the filesystem hands the files over;
#   * every file carries the same timestamp, so the bytes do not depend on
#     when the build ran;
#   * the archive records owner 0 and group 0, so the bytes do not depend on
#     which user ran the build.
#
# The two tar implementations the matrix uses disagree about the flags that
# do this — GNU tar has `--sort=name`, `--mtime` and `--owner`, and the
# bsdtar on macOS has `--uid`, `--gid` and no `--mtime` at all — so the
# ownership flags are chosen by the tar that is present, and the timestamp is
# set on the files themselves, which both implementations record faithfully.
#
# usage: package-release.sh <target>
set -euo pipefail

target="${1:?usage: package-release.sh <target>}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

version="$(awk -F'"' '/^[[:space:]]*version: "/ { print $2; exit }' mix.exs)"
# The release name is the key of the `releases:` list. `sed` rather than
# `awk`: the pattern needs a literal `[`, and the escaping an `awk` program
# wants for it is not the escaping a `sed` pattern wants, and the two `awk`
# implementations do not agree on it either.
release_name="$(sed -n 's/^[[:space:]]*releases:[[:space:]]*\[\([[:alnum:]_]\{1,\}\):.*/\1/p' mix.exs | head -1)"
release_name="${release_name:-veritas}"

release_dir="_build/prod/rel/$release_name"

if [ ! -d "$release_dir" ]; then
  echo "no release at $release_dir — run 'mix release' first" >&2
  exit 1
fi

out="dist"
mkdir -p "$out"
artifact="veritas-$version-$target.tar.gz"

# The stage is a copy, so the build tree is not mutated and the operator's
# files are added without touching what `mix release` produced.
stage="$(mktemp -d)"
member_list="$(mktemp)"
# The cleanup is best-effort: a failure to remove the temporary files must
# not change the script's exit status, which is the result of the packaging.
trap 'rm -rf "$stage" "$member_list" 2>/dev/null || true' EXIT

cp -R "$release_dir/." "$stage/"

# The operator's files travel with the release: the installer reads the
# service templates from the release home's `ops` directory, and a release
# without them cannot install anything.
if [ -d ops ]; then
  cp -R ops "$stage/ops"
fi

# One timestamp for every member. `SOURCE_DATE_EPOCH` is the contract, and
# the two `date` implementations spell "seconds since the epoch" differently,
# so both are tried.
epoch="${SOURCE_DATE_EPOCH:-0}"
stamp=""
if date -u -d "@$epoch" '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
  stamp="$(date -u -d "@$epoch" '+%Y%m%d%H%M.%S')"
elif date -u -r "$epoch" '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
  stamp="$(date -u -r "$epoch" '+%Y%m%d%H%M.%S')"
else
  # The epoch itself, in the form `touch -t` takes everywhere.
  stamp="197001010000.00"
fi

# Set the timestamp on the files, so neither tar has to be told about it.
TZ=UTC find "$stage" -exec touch -t "$stamp" {} +

# One member order, on every platform. The list is written outside the
# stage, so it does not end up in the archive.
#
# Only files are listed, never directories: a member list that names a
# directory makes the archive walk it in whatever order the filesystem hands
# the entries over, which is exactly the order the archive must not depend
# on. The directories are created when the archive is unpacked.
( cd "$stage" && find . \( -type f -o -type l \) -print | LC_ALL=C sort ) > "$member_list"

# The ownership flags are the one thing the two implementations spell
# differently: GNU tar takes `--owner`/`--group`, and bsdtar takes
# `--uid`/`--gid`/`--uname`/`--gname`. Everything else is the same.
if tar --sort=name --version >/dev/null 2>&1; then
  ownership=(--owner=0 --group=0 --numeric-owner)
else
  ownership=(--uid=0 --gid=0 --uname=root --gname=root)
fi

# The archive is written through `gzip -n` rather than with `tar -czf`:
# the gzip header of a compressed tarball records the time of the
# compression unless it is told not to, and the two tar implementations
# differ on what they write there — GNU tar's gzip child reads a pipe and
# records nothing, and the bsdtar on macOS compresses in process and
# records the current time. `-n` writes neither the name nor the time, so
# the bytes depend on the contents and not on when the build ran.
tar "${ownership[@]}" \
    -cf - \
    -C "$stage" \
    -T "$member_list" \
  | gzip -n > "$out/$artifact"

# The checksum is the same bytes whichever tool computes it: `sha256sum` on
# Linux, `shasum -a 256` on macOS, which prints the same
# "<digest>  <file>" line.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$out" && sha256sum "$artifact" > "SHA256SUMS-$target.txt" )
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$out" && shasum -a 256 "$artifact" > "SHA256SUMS-$target.txt" )
else
  echo "neither sha256sum nor shasum is on PATH" >&2
  exit 1
fi

echo "packaged $out/$artifact"
