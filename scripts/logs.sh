#!/usr/bin/env bash
# scripts/logs.sh
#
# Convenience wrapper around `docker logs` for VPS containers.
# Run on the VPS as the deploy user.
#
# Usage:
#   ./scripts/logs.sh                      # sovereign-runtime, follow, last 100 lines
#   ./scripts/logs.sh runtime              # sovereign-runtime
#   ./scripts/logs.sh auth                 # sovereign-auth
#   ./scripts/logs.sh postgres             # sovereign-postgres
#   ./scripts/logs.sh caddy               # caddy
#   ./scripts/logs.sh runtime --tail 50   # last 50 lines, then follow
#   ./scripts/logs.sh runtime --no-follow  # dump without following
#
# Aliases: r=runtime, a=auth, p=postgres, c=caddy

set -euo pipefail

TARGET="${1:-runtime}"
shift || true

FOLLOW=true
TAIL=100

# Parse remaining flags
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-follow|-n) FOLLOW=false ;;
    --tail|-t)      TAIL="${2:-100}"; shift ;;
    *)              EXTRA_ARGS+=("$1") ;;
  esac
  shift
done

resolve_container() {
  case "$1" in
    r|runtime)  echo "sovereign-runtime" ;;
    a|auth)     echo "sovereign-auth" ;;
    p|postgres) echo "sovereign-postgres" ;;
    c|caddy)    echo "caddy" ;;
    *)          echo "$1" ;;  # pass through for direct container names
  esac
}

CONTAINER=$(resolve_container "$TARGET")

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Container not running: $CONTAINER" >&2
  echo "Running containers:" >&2
  docker ps --format '  {{.Names}} ({{.Status}})' >&2
  exit 1
fi

CMD=(docker logs "$CONTAINER" --tail "$TAIL" "${EXTRA_ARGS[@]}")
[[ "$FOLLOW" == "true" ]] && CMD+=(-f)

echo "==> ${CONTAINER} (last ${TAIL} lines$([ "$FOLLOW" = true ] && echo ', following' || echo ''))"
"${CMD[@]}"
