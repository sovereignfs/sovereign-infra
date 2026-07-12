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

if ! command -v age &>/dev/null; then
  echo "Error: age is not installed (or not on PATH)." >&2
  echo "A VPS bootstrapped with the current bootstrap/setup.sh has age" >&2
  echo "preinstalled system-wide — if you're seeing this, either re-run" >&2
  echo "bootstrap/setup.sh (as root) or install it yourself:" >&2
  echo "  curl -fsSL https://github.com/FiloSottile/age/releases/download/v1.2.0/age-v1.2.0-linux-amd64.tar.gz \\" >&2
  echo "    | tar xz --strip-components=1 -C ~/bin age/age age/age-keygen   # no sudo needed" >&2
  echo "  export PATH=\"\$HOME/bin:\$PATH\"" >&2
  exit 1
fi

mkdir -p "/opt/apps/$APP"

if [[ -n "$KEY_FILE" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    echo "Error: key file not found: $KEY_FILE" >&2
    echo "The age PRIVATE key is not provisioned on the VPS by default (by" >&2
    echo "design — see docs/sovereign-deploy-workflow.md's 'Applying an env" >&2
    echo "change manually' section). Copy it over first — from your LOCAL" >&2
    echo "machine (not this VPS):" >&2
    echo "  ssh $(whoami)@<VPS_HOST> 'mkdir -p ~/.age && chmod 700 ~/.age'" >&2
    echo "  scp ~/.age/key.txt $(whoami)@<VPS_HOST>:~/.age/key.txt" >&2
    exit 1
  fi
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
