#!/usr/bin/env bash
# scripts/encrypt-env.sh
#
# Encrypts apps/<name>/.env into apps/<name>/.env.enc using the age public key.
# Run this locally whenever you create or update a .env file.
# The .env.enc output is committed to git. The .env source is NOT.
#
# Usage:
#   ./scripts/encrypt-env.sh sovereign
#   ./scripts/encrypt-env.sh myapp
#
# Requirements:
#   - age installed (brew install age / apt install age)
#   - AGE_PUBLIC_KEY set in your shell, or passed as env var:
#       AGE_PUBLIC_KEY=age1... ./scripts/encrypt-env.sh sovereign

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "Usage: $0 <app-name>" >&2
  echo "  e.g. $0 sovereign" >&2
  exit 1
fi

ENV_FILE="apps/$APP/.env"
ENC_FILE="apps/$APP/.env.enc"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found." >&2
  echo "Create it from the template first:" >&2
  echo "  cp apps/$APP/.env.example apps/$APP/.env" >&2
  exit 1
fi

if [[ -z "${AGE_PUBLIC_KEY:-}" ]]; then
  echo "Error: AGE_PUBLIC_KEY is not set." >&2
  echo "Export it first:" >&2
  echo "  export AGE_PUBLIC_KEY=age1..." >&2
  echo "Your public key is in your age key file or your password manager." >&2
  exit 1
fi

age -r "$AGE_PUBLIC_KEY" -o "$ENC_FILE" "$ENV_FILE"
echo "Encrypted: $ENC_FILE"
echo "Commit this file to git. Do NOT commit $ENV_FILE."
