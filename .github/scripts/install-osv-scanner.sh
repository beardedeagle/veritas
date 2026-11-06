#!/usr/bin/env bash
# Install the pinned osv-scanner the advisory sweep uses.
#
# Pinned by version and verified against the published checksums, so the
# scanner itself is part of the pipeline's supply chain and not an
# assumption. The same script is used by every job that sweeps, so there is
# one place that knows which scanner the project runs.
#
# Environment:
#
#   OSV_SCANNER_VERSION  the release to install. Default: v2.7.0.
set -euo pipefail

version="${OSV_SCANNER_VERSION:-v2.7.0}"
base="https://github.com/google/osv-scanner/releases/download/${version}"
asset="osv-scanner_linux_amd64"

cd "$(mktemp -d)"
curl -sSfL -o "$asset" "$base/$asset"
curl -sSfL -o SHA256SUMS "$base/osv-scanner_SHA256SUMS"
grep " $asset\$" SHA256SUMS | sha256sum -c -

install -m 0755 "$asset" /usr/local/bin/osv-scanner

osv-scanner --version
