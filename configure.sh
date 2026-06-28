#!/usr/bin/env bash
# configure.sh
#
# One-time setup: stamps your domain names into the config files.
# Run this once after forking / using this template.
#
# What it does:
#   - Replaces YOUR_RUNTIME_DOMAIN, YOUR_AUTH_DOMAIN, YOUR_ROOT_DOMAIN
#     in caddy/conf.d/sovereign.caddy and apps/sovereign/.env.example
#
# Usage:
#   ./configure.sh
#
# You can re-run it at any time to update your domains.

set -euo pipefail

# ── Terminal helpers ───────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
red() { printf '\033[31m%s\033[0m' "$*"; }

# ── Validate domain input ──────────────────────────────────────────────────────
# Must contain a dot, no http/https prefix, no trailing slash.
validate_domain() {
  local domain="$1"
  local label="$2"
  if [[ "$domain" == http://* || "$domain" == https://* ]]; then
    echo "$(red "Error:") $label must not include http:// or https://" >&2
    return 1
  fi
  if [[ "$domain" != *.* ]]; then
    echo "$(red "Error:") $label must contain at least one dot (e.g. sovereign.example.com)" >&2
    return 1
  fi
  if [[ "$domain" == */ ]]; then
    echo "$(red "Error:") $label must not end with a slash" >&2
    return 1
  fi
  return 0
}

# ── Prompt ────────────────────────────────────────────────────────────────────
echo ""
echo "$(bold 'Sovereign Infra — domain configuration')"
echo ""
echo "This configures the three domain placeholders used throughout this repo."
echo "You can re-run this script at any time to update your domains."
echo ""
echo "  Runtime domain  — where the main app is served (e.g. sovereign.example.com)"
echo "  Auth domain     — where the auth server is served (e.g. auth.example.com)"
echo "  Root domain     — the registrable domain root (e.g. example.com)"
echo "                    Used for WebAuthn RP_ID, cookie domain, and email sender."
echo ""

while true; do
  read -r -p "$(bold 'Runtime domain') (e.g. sovereign.example.com): " RUNTIME_DOMAIN
  validate_domain "$RUNTIME_DOMAIN" "Runtime domain" && break
done

while true; do
  read -r -p "$(bold 'Auth domain')    (e.g. auth.example.com):      " AUTH_DOMAIN
  validate_domain "$AUTH_DOMAIN" "Auth domain" && break
done

# Derive root domain suggestion from runtime domain (strip first label)
SUGGESTED_ROOT=$(echo "$RUNTIME_DOMAIN" | cut -d. -f2-)
while true; do
  read -r -p "$(bold 'Root domain')    (e.g. example.com) [$SUGGESTED_ROOT]: " ROOT_DOMAIN
  ROOT_DOMAIN="${ROOT_DOMAIN:-$SUGGESTED_ROOT}"
  validate_domain "$ROOT_DOMAIN" "Root domain" && break
done

echo ""
echo "About to configure:"
echo "  Runtime domain  → $(bold "$RUNTIME_DOMAIN")"
echo "  Auth domain     → $(bold "$AUTH_DOMAIN")"
echo "  Root domain     → $(bold "$ROOT_DOMAIN")"
echo ""
read -r -p "Proceed? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }

# ── In-place substitution ──────────────────────────────────────────────────────
SED_CMD=sed
SED_INPLACE=(-i)
if command -v gsed &>/dev/null; then
  SED_CMD=gsed  # prefer GNU sed on macOS (brew install gnu-sed)
elif [[ "$OSTYPE" == "darwin"* ]]; then
  SED_INPLACE=(-i '')  # BSD sed requires empty extension string
fi

do_replace() {
  local file="$1"
  "$SED_CMD" "${SED_INPLACE[@]}" \
    -e "s|YOUR_RUNTIME_DOMAIN|${RUNTIME_DOMAIN}|g" \
    -e "s|YOUR_AUTH_DOMAIN|${AUTH_DOMAIN}|g" \
    -e "s|YOUR_ROOT_DOMAIN|${ROOT_DOMAIN}|g" \
    "$file"
}

FILES=(
  "caddy/conf.d/sovereign.caddy"
  "apps/sovereign/.env.example"
  "docs/ports.md"
)

echo ""
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    do_replace "$f"
    echo "  $(green '✓') $f"
  else
    echo "  $(yellow '?') $f not found — skipped"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "$(green 'Done.')  Your domains are now configured."
echo ""
echo "$(bold 'Next steps:')"
echo ""
echo "  1. Review the changes:"
echo "     git diff"
echo ""
echo "  2. Commit the updated config (these files contain no secrets):"
echo "     git add caddy/conf.d/sovereign.caddy apps/sovereign/.env.example docs/ports.md"
echo "     git commit -m 'config: set domain to ${RUNTIME_DOMAIN}'"
echo ""
echo "  3. Create your .env and encrypt it:"
echo "     cp apps/sovereign/.env.example apps/sovereign/.env"
echo "     nano apps/sovereign/.env   # fill in AUTH_SECRET, SOVEREIGN_ADMIN_KEY, POSTGRES_PASSWORD, etc."
echo "     ./scripts/encrypt-env.sh sovereign"
echo "     git add apps/sovereign/.env.enc && git commit -m 'secrets: sovereign initial'"
echo ""
echo "  4. (Optional) Enable the compose override to fix upstream env var gaps:"
echo "     cp apps/sovereign/docker-compose.override.yml.example \\"
echo "        apps/sovereign/docker-compose.override.yml"
echo "     git add apps/sovereign/docker-compose.override.yml"
echo "     git commit -m 'config: enable compose override'"
echo ""
echo "  5. Follow the README for VPS bootstrap and first deploy."
echo ""
echo "  DNS records to add (both pointing to your VPS IP):"
echo "     A  ${RUNTIME_DOMAIN}  <VPS IP>"
echo "     A  ${AUTH_DOMAIN}     <VPS IP>"
echo ""
