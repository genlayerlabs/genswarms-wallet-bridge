#!/usr/bin/env bash
# Co-versioning check for package, vectors, and webapp stamps. Contract bytes
# keep their independent CONTRACT_VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."

v="$(cat VERSION)"

[ "$(cat vectors/VERSION)" = "${v}" ] \
  || { echo "FAIL: vectors/VERSION != ${v}"; exit 1; }

grep -q "version: \"${v}\"" mix.exs \
  || { echo "FAIL: mix.exs version != ${v}"; exit 1; }

grep -q "\"version\": \"${v}\"" webapp/config.json \
  || { echo "FAIL: webapp/config.json version != ${v}"; exit 1; }

cv="$(cat CONTRACT_VERSION)"
# Contracts version independently: 0.3.0 ships zero contract changes, so the
# .sol literal (and every deployed codehash pin) stays at the contract line's
# own version. Bump CONTRACT_VERSION only when contract bytes change.
grep -q "return \"${cv}\";" contracts/src/SpendRouter.sol \
  || { echo "FAIL: SpendRouter.version() literal != ${cv}"; exit 1; }

echo "version stamp OK: ${v}"
