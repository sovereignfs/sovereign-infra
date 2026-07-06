#!/usr/bin/env bash
# /opt/scripts/restore-sovereign.sh
#
# Restore Sovereign from an encrypted backup.
#
# Restores four components (all optional — restores only what backup files exist):
#   1. Postgres database
#   2. User avatars
#   3. Plugin manifest (sovereign.plugins.json)
#   4. Isolated plugin databases (plugins/*.db)
#
# Usage:
#   ./restore-sovereign.sh <date>  e.g.  ./restore-sovereign.sh 20260627-030000
#
# Run on the VPS as the deploy user.
# Requires: age private key at ~/.age/key.txt (or AGE_PRIVATE_KEY env var,
#           or AGE_KEY_FILE pointing to your key file)

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

DATE="${1:-}"
REPO_DIR="${BACKUP_REPO_DIR:-/opt/backups-repo}"

# ── Ensure backup repo is present and up to date ──────────────────────────────
if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "Error: backup repo not found at $REPO_DIR" >&2
  echo "Run install-backup-cron.sh first to clone it, or:" >&2
  echo "  source /opt/apps/sovereign/.env" >&2
  echo "  git clone https://x-access-token:\$BACKUP_GITHUB_TOKEN@github.com/\$BACKUP_GITHUB_REPO.git $REPO_DIR" >&2
  exit 1
fi

echo "==> Pulling latest backups..."
git -C "$REPO_DIR" pull origin main

if [[ -z "$DATE" ]]; then
  echo "Usage: $0 <date>  e.g.  $0 20260627-030000"
  echo ""
  echo "Available backups:"
  ls "$REPO_DIR/sovereign/db-"*.sql.gz.enc 2>/dev/null \
    | grep -oP '\d{8}-\d{6}' | sort -r \
    || echo "(none found)"
  exit 1
fi

# ── Resolve age key ───────────────────────────────────────────────────────────
decrypt() {
  local input="$1"
  if [[ -f "${AGE_KEY_FILE:-$HOME/.age/key.txt}" ]]; then
    age -d -i "${AGE_KEY_FILE:-$HOME/.age/key.txt}" "$input"
  elif [[ -n "${AGE_PRIVATE_KEY:-}" ]]; then
    echo "$AGE_PRIVATE_KEY" | age -d -i - "$input"
  else
    echo "Error: no age key found." >&2
    echo "Place key at ~/.age/key.txt or set AGE_PRIVATE_KEY or AGE_KEY_FILE." >&2
    exit 1
  fi
}

# ── Load env ──────────────────────────────────────────────────────────────────
set -a
source /opt/apps/sovereign/.env
set +a

# ── Locate backup files ───────────────────────────────────────────────────────
DB_ENC="$REPO_DIR/sovereign/db-${DATE}.sql.gz.enc"
AVATARS_ENC="$REPO_DIR/sovereign/avatars-${DATE}.tar.gz.enc"
MANIFEST_ENC="$REPO_DIR/sovereign/plugins-manifest-${DATE}.json.enc"
PLUGIN_DBS_ENC="$REPO_DIR/sovereign/plugin-dbs-${DATE}.tar.gz.enc"

[[ -f "$DB_ENC" ]] || { echo "Error: database backup not found: $DB_ENC"; exit 1; }

echo "Restore plan for backup: $DATE"
echo ""
echo "  [required] Postgres database:    $DB_ENC"
[[ -f "$AVATARS_ENC" ]]    && echo "  [found]    User avatars:           $AVATARS_ENC" \
                           || echo "  [missing]  User avatars:           (skipped — not in this backup)"
[[ -f "$MANIFEST_ENC" ]]   && echo "  [found]    Plugin manifest:        $MANIFEST_ENC" \
                           || echo "  [missing]  Plugin manifest:        (skipped)"
[[ -f "$PLUGIN_DBS_ENC" ]] && echo "  [found]    Isolated plugin DBs:   $PLUGIN_DBS_ENC" \
                           || echo "  [missing]  Isolated plugin DBs:   (skipped — no isolated plugins in this backup)"
echo ""
echo "This will STOP runtime and auth containers and OVERWRITE current data."
read -r -p "Are you sure? (yes/N): " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

cd /opt/apps/sovereign

# ── Stop runtime and auth (leave Postgres running for the restore) ────────────
echo ""
echo "==> Stopping runtime and auth..."
docker compose stop runtime auth

# ── 1. Restore Postgres ───────────────────────────────────────────────────────
echo "==> Restoring Postgres database..."
decrypt "$DB_ENC" \
  | gunzip \
  | docker exec -i sovereign-postgres \
      psql -U "${POSTGRES_USER:-sovereign}" "${POSTGRES_DB:-sovereign}"
echo "    Database restored."

# ── 2. Restore avatars ────────────────────────────────────────────────────────
if [[ -f "$AVATARS_ENC" ]]; then
  echo "==> Restoring user avatars..."
  docker run --rm -i \
    -v sovereign_data:/data \
    alpine \
    sh -c "mkdir -p /data/avatars && rm -rf /data/avatars/* && tar xzf - -C /data/avatars" \
    < <(decrypt "$AVATARS_ENC")
  echo "    Avatars restored."
fi

# ── 3. Restore plugin manifest ────────────────────────────────────────────────
if [[ -f "$MANIFEST_ENC" ]]; then
  echo "==> Restoring plugin manifest..."
  decrypt "$MANIFEST_ENC" \
    | docker run --rm -i \
        -v sovereign_data:/data \
        alpine \
        sh -c "cat > /data/sovereign.plugins.json"
  echo "    Plugin manifest restored."
fi

# ── 4. Restore isolated plugin databases ──────────────────────────────────────
if [[ -f "$PLUGIN_DBS_ENC" ]]; then
  echo "==> Restoring isolated plugin databases..."
  docker run --rm -i \
    -v sovereign_data:/data \
    alpine \
    sh -c "mkdir -p /data/plugins && rm -rf /data/plugins/*.db && tar xzf - -C /data/plugins" \
    < <(decrypt "$PLUGIN_DBS_ENC")
  echo "    Plugin databases restored."
fi

# ── Restart ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Restarting containers..."
docker compose up -d

echo ""
echo "Restore complete from backup: $DATE"
echo ""
echo "What was restored:"
echo "  ✓ Postgres database (runtime + auth data)"
[[ -f "$AVATARS_ENC" ]]    && echo "  ✓ User avatars"
[[ -f "$MANIFEST_ENC" ]]   && echo "  ✓ Plugin manifest (sovereign.plugins.json)"
[[ -f "$PLUGIN_DBS_ENC" ]] && echo "  ✓ Isolated plugin databases"
echo ""
echo "Note: plugin assets (JS bundles) are re-fetched from the registry on next start."
