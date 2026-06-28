#!/usr/bin/env bash
# scripts/fetch-env-example.sh
#
# Refreshes the upstream section of apps/sovereign/.env.example from the
# sovereignfs/sovereign repo (main branch), preserving the deployment-specific
# block at the bottom of the local file.
#
# Run this when sovereign adds new environment variables:
#   ./scripts/fetch-env-example.sh
#
# The script splices: upstream content + the local "deployment overrides" block
# (everything after the ══ separator line).

set -euo pipefail

APP="${1:-sovereign}"
LOCAL_ENV="apps/$APP/.env.example"
UPSTREAM_URL="https://raw.githubusercontent.com/sovereignfs/sovereign/main/.env.example"
SEPARATOR="# ══ deployment overrides"

if [[ ! -f "$LOCAL_ENV" ]]; then
  echo "Error: $LOCAL_ENV not found." >&2
  echo "  Run from the root of the infra repo." >&2
  exit 1
fi

echo "Fetching upstream .env.example from sovereignfs/sovereign@main..."
UPSTREAM=$(curl -fsSL "$UPSTREAM_URL") || {
  echo "Error: could not fetch $UPSTREAM_URL" >&2
  exit 1
}

# Extract the local deployment-specific block (separator line and everything after)
LOCAL_BLOCK=$(awk "/$SEPARATOR/{found=1} found{print}" "$LOCAL_ENV")

if [[ -z "$LOCAL_BLOCK" ]]; then
  echo "Error: separator line not found in $LOCAL_ENV:" >&2
  echo "  $SEPARATOR" >&2
  echo "  Cannot safely splice — aborting." >&2
  exit 1
fi

# Write: header comment + upstream content + blank line + local block
{
  echo "# Sovereign environment configuration."
  echo "#"
  echo "# Upstream section auto-synced from sovereignfs/sovereign/.env.example"
  echo "# via scripts/fetch-env-example.sh — do not edit above the separator line."
  echo "# Deployment-specific overrides live below the separator."
  echo ""
  echo "$UPSTREAM"
  echo ""
  echo "$LOCAL_BLOCK"
} > "$LOCAL_ENV"

echo "Updated: $LOCAL_ENV"
echo ""
echo "Review the diff, then commit:"
echo "  git diff $LOCAL_ENV"
echo "  git add $LOCAL_ENV && git commit -m 'chore: sync sovereign .env.example'"
