#!/usr/bin/env bash
# scripts/decrypt-env.sh
#
# Decrypts apps/<name>/.env.enc into /opt/apps/<name>/.env on the VPS.
# Run during initial provisioning or whenever secrets are rotated.
#
# Usage:
#   ./scripts/decrypt-env.sh sovereign          # reads AGE_PRIVATE_KEY from env
#   ./scripts/decrypt-env.sh sovereign /path/to/key.txt  # reads key from file
#
# In CI (GitHub Actions), AGE_PRIVATE_KEY is set from a GitHub secret.
# On the VPS directly, pass the key file path or export AGE_PRIVATE_KEY.

set -euo pipefail

APP="${1:-}"
KEY_FILE="${2:-}"

if [[ -z "$APP" ]]; then
  echo "Usage: $0 <app-name> [key-file]" >&2
  exit 1
fi

ENC_FILE="apps/$APP/.env.enc"
OUT_FILE="/opt/apps/$APP/.env"

if [[ ! -f "$ENC_FILE" ]]; then
  echo "Error: $ENC_FILE not found. Pull the latest infra repo first." >&2
  exit 1
fi

mkdir -p "/opt/apps/$APP"

if [[ -n "$KEY_FILE" ]]; then
  # Key from file
  age -d -i "$KEY_FILE" -o "$OUT_FILE" "$ENC_FILE"
elif [[ -n "${AGE_PRIVATE_KEY:-}" ]]; then
  # Key from environment variable (used in CI)
  echo "$AGE_PRIVATE_KEY" | age -d -i - -o "$OUT_FILE" "$ENC_FILE"
else
  echo "Error: no key provided." >&2
  echo "Either:" >&2
  echo "  Pass a key file: $0 $APP ~/.age/key.txt" >&2
  echo "  Or set AGE_PRIVATE_KEY env var (used in CI)" >&2
  exit 1
fi

chmod 600 "$OUT_FILE"
echo "Decrypted: $OUT_FILE"
