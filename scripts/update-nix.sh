#!/usr/bin/env bash
# Update the Nix dependency hash from the current pnpm-lock.yaml.
# Requires: nix
#
# Usage:
#   ./scripts/update-nix.sh          # update hash if stale
#   ./scripts/update-nix.sh --check  # verify the hash is up to date (CI mode)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HASH_FILE="$ROOT_DIR/nix/pnpm-deps.hash"

CHECK_MODE=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_MODE=true
fi

# Build the pnpmDeps FOD. On hash mismatch nix prints the actual hash,
# which we parse out of stderr. This is the standard way to discover
# an FOD's content hash for downstream consumers.
echo "Computing pnpm-deps hash from current pnpm-lock.yaml..."

# Force a hash mismatch by temporarily writing the standard fakeHash, build,
# and read the suggested hash from stderr. Restore on exit.
STDERR_LOG="$(mktemp)"
ORIG_HASH="$(tr -d '[:space:]' < "$HASH_FILE")"
trap 'rm -f "$STDERR_LOG"; printf "%s\n" "$ORIG_HASH" > "$HASH_FILE"' EXIT

printf 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$HASH_FILE"

if nix build --no-link --impure ".#packages.x86_64-linux.default.pnpmDeps" \
    2> "$STDERR_LOG"; then
  echo "ERROR: pnpmDeps build unexpectedly succeeded with fakeHash"
  exit 1
fi

NEW_HASH="$(grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' "$STDERR_LOG" || true)"
if [[ -z "$NEW_HASH" ]]; then
  echo "ERROR: could not parse new hash from nix build output:" >&2
  tail -20 "$STDERR_LOG" >&2
  exit 1
fi

echo "Computed hash: $NEW_HASH"

# Compare and write
if [[ "$NEW_HASH" == "$ORIG_HASH" ]]; then
  echo "Hash is already up to date."
  # trap restores ORIG_HASH on exit; that's a no-op here
else
  if $CHECK_MODE; then
    echo "ERROR: pnpmDepsHash is stale."
    echo "  current: $ORIG_HASH"
    echo "  correct: $NEW_HASH"
    echo "Run ./scripts/update-nix.sh to fix."
    exit 1
  fi

  printf '%s\n' "$NEW_HASH" > "$HASH_FILE"
  trap 'rm -f "$STDERR_LOG"' EXIT
  echo "Updated: $ORIG_HASH -> $NEW_HASH"
fi
