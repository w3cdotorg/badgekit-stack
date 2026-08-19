#!/usr/bin/env bash
# Generates an OB 3.0 issuer signing key (Ed25519/Multikey) via the api
# service's bin/generate-issuer-key.js, and writes/updates ISSUER_DID +
# ISSUER_SIGNING_KEY in .env (gitignored — see global-constraints.md: the
# key is never committed, never stored in the DB, never baked into the
# image).
#
# Usage:
#   ./gen-dev-key.sh                                   # did:web:localhost%3A8080
#   ./gen-dev-key.sh 'did:web:<random>.trycloudflare.com'   # spike / external validation
#
# After running, bring the api service up (or restart it) so it picks up
# the new .env values:
#   docker compose up -d --build api
set -euo pipefail

cd "$(dirname "$0")"

DID="${1:-did:web:localhost%3A8080}"
ENV_FILE=".env"

echo "Generating issuer key for DID: $DID" >&2

OUTPUT="$(docker compose run --rm --no-deps api node bin/generate-issuer-key.js "$DID")"

ISSUER_DID_LINE="$(echo "$OUTPUT" | grep '^export ISSUER_DID=' | sed 's/^export //')"
ISSUER_SIGNING_KEY_LINE="$(echo "$OUTPUT" | grep '^export ISSUER_SIGNING_KEY=' | sed 's/^export //')"

if [ -z "$ISSUER_DID_LINE" ] || [ -z "$ISSUER_SIGNING_KEY_LINE" ]; then
  echo "Failed to parse ISSUER_DID / ISSUER_SIGNING_KEY from generator output:" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

touch "$ENV_FILE"

# Strip any previous ISSUER_DID / ISSUER_SIGNING_KEY lines, then append the
# fresh pair, so re-running this script is idempotent (no duplicate/stale
# entries piling up in .env).
TMP_FILE="$(mktemp)"
grep -v '^ISSUER_DID=' "$ENV_FILE" | grep -v '^ISSUER_SIGNING_KEY=' > "$TMP_FILE" || true
mv "$TMP_FILE" "$ENV_FILE"

{
  echo "$ISSUER_DID_LINE"
  echo "$ISSUER_SIGNING_KEY_LINE"
} >> "$ENV_FILE"

echo "" >&2
echo "Wrote $ISSUER_DID_LINE to $ENV_FILE" >&2
echo "Wrote ISSUER_SIGNING_KEY=<redacted> to $ENV_FILE" >&2
echo "" >&2
echo "Next: docker compose up -d --build api" >&2
