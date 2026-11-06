#!/usr/bin/env bash
# Install the pinned gitleaks the secret scan uses.
#
# Pinned by version and verified against the published checksums, so the
# scanner itself is part of the pipeline's supply chain and not an
# assumption. The same script is used by every job that scans, so there is
# one place that knows which scanner the project runs.
#
# Environment:
#
#   GITLEAKS_VERSION  the release to install. Default: v8.30.1.
set -euo pipefail

version="${GITLEAKS_VERSION:-v8.30.1}"
base="https://github.com/gitleaks/gitleaks/releases/download/${version}"
asset="gitleaks_${version#v}_linux_x64.tar.gz"

cd "$(mktemp -d)"
curl -sSfL -o "$asset" "$base/$asset"
curl -sSfL -o "checksums.txt" "$base/gitleaks_${version#v}_checksums.txt"
grep " ${asset}\$" checksums.txt | sha256sum -c -

tar -xzf "$asset" gitleaks
install -m 0755 gitleaks /usr/local/bin/gitleaks

gitleaks version
