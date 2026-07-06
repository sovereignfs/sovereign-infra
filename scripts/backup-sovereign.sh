#!/usr/bin/env bash
# /opt/scripts/backup-sovereign.sh
#
# Daily backup for Sovereign. Backs up four distinct things:
#
#   1. Postgres database      → pg_dump | gzip | age encrypt
#   2. User avatars           → tar | age encrypt
#   3. Plugin manifests       → sovereign.plugins.json | age encrypt
#   4. Isolated plugin DBs    → plugins/*.db | tar | age encrypt
#      (SQLite files for plugins with database: "isolated" — NOT in Postgres)
#
# All output is age-encrypted before leaving the VPS.
# Pushed to $BACKUP_GITHUB_REPO as a single dated commit.
# Commits older than RETENTION_DAYS are pruned automatically.
#
# Runs as the deploy user via cron at 03:00 UTC.
# Install: /opt/infra/scripts/install-backup-cron.sh

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ── Load env ──────────────────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
source /opt/apps/sovereign/.env
set +a

# ── Config ────────────────────────────────────────────────────────────────────
DATE=$(date -u +%Y%m%d-%H%M%S)
BACKUP_DIR=/tmp/sovereign-backup-$$
REPO_DIR="${BACKUP_REPO_DIR:-/opt/backups-repo}"
RETENTION_DAYS=30
POSTGRES_CONTAINER=sovereign-postgres
RUNTIME_CONTAINER=sovereign-runtime

mkdir -p "$BACKUP_DIR/sovereign"
trap 'rm -rf "$BACKUP_DIR"' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── 1. Postgres database ──────────────────────────────────────────────────────
# Contains: runtime platform data + auth identity tables (users, sessions, MFA)
log "Dumping Postgres..."
docker exec "$POSTGRES_CONTAINER" \
  pg_dump -U "${POSTGRES_USER:-sovereign}" "${POSTGRES_DB:-sovereign}" \
  | gzip \
  | age -r "$AGE_PUBLIC_KEY" \
  > "$BACKUP_DIR/sovereign/db-${DATE}.sql.gz.enc"
log "  → $(du -sh "$BACKUP_DIR/sovereign/db-${DATE}.sql.gz.enc" | cut -f1)"

# ── 2. User avatars ───────────────────────────────────────────────────────────
# Location inside sovereign_data volume: avatars/
# Skip if empty (new instance with no avatars yet)
log "Backing up avatars..."
AVATAR_COUNT=$(docker run --rm \
  -v sovereign_data:/data:ro \
  alpine sh -c 'ls /data/avatars/ 2>/dev/null | wc -l' || echo 0)

if [[ "$AVATAR_COUNT" -gt 0 ]]; then
  docker run --rm \
    -v sovereign_data:/data:ro \
    alpine tar czf - -C /data/avatars . \
    | age -r "$AGE_PUBLIC_KEY" \
    > "$BACKUP_DIR/sovereign/avatars-${DATE}.tar.gz.enc"
  log "  → $(du -sh "$BACKUP_DIR/sovereign/avatars-${DATE}.tar.gz.enc" | cut -f1) ($AVATAR_COUNT files)"
else
  log "  → skipped (no avatars)"
fi

# ── 3. Plugin manifest ────────────────────────────────────────────────────────
# sovereign.plugins.json — records which plugins are installed on this instance.
# Without this, restoring the DB alone won't reinstall plugins automatically.
# Location: written to /app/data/sovereign.plugins.json inside the runtime container.
log "Backing up plugin manifest..."
MANIFEST=$(docker exec "$RUNTIME_CONTAINER" \
  cat /app/data/sovereign.plugins.json 2>/dev/null || echo '{"plugins":[]}')

echo "$MANIFEST" \
  | age -r "$AGE_PUBLIC_KEY" \
  > "$BACKUP_DIR/sovereign/plugins-manifest-${DATE}.json.enc"
PLUGIN_COUNT=$(echo "$MANIFEST" | jq -r '.plugins | length' 2>/dev/null || echo '?')
log "  → ${PLUGIN_COUNT} plugin(s)"

# ── 4. Isolated plugin databases ──────────────────────────────────────────────
# Plugins with database: "isolated" get their own SQLite file under:
#   sovereign_data:/data/plugins/<pluginId>.db
# These are NOT in Postgres — they must be backed up separately.
# The directory only exists if at least one isolated plugin has been activated.
log "Backing up isolated plugin databases..."
PLUGIN_DB_COUNT=$(docker run --rm \
  -v sovereign_data:/data:ro \
  alpine sh -c 'ls /data/plugins/*.db 2>/dev/null | wc -l' || echo 0)

if [[ "$PLUGIN_DB_COUNT" -gt 0 ]]; then
  # List the plugin IDs being backed up for the log
  PLUGIN_IDS=$(docker run --rm \
    -v sovereign_data:/data:ro \
    alpine sh -c 'ls /data/plugins/*.db 2>/dev/null | xargs -n1 basename | sed "s/\.db$//"')
  log "  Found $PLUGIN_DB_COUNT isolated plugin DB(s): $(echo "$PLUGIN_IDS" | tr '\n' ' ')"

  docker run --rm \
    -v sovereign_data:/data:ro \
    alpine tar czf - -C /data/plugins . \
    | age -r "$AGE_PUBLIC_KEY" \
    > "$BACKUP_DIR/sovereign/plugin-dbs-${DATE}.tar.gz.enc"
  log "  → $(du -sh "$BACKUP_DIR/sovereign/plugin-dbs-${DATE}.tar.gz.enc" | cut -f1)"
else
  log "  → skipped (no isolated plugin databases found)"
fi

# ── 5. Push to GitHub ─────────────────────────────────────────────────────────
log "Pushing to ${BACKUP_GITHUB_REPO}..."

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "Error: backup repo is not cloned at $REPO_DIR." >&2
  echo "Run /opt/infra/scripts/install-backup-cron.sh first." >&2
  exit 1
fi

cd "$REPO_DIR"
git config user.email "backup@sovereign"
git config user.name "Sovereign Backup"

if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  git fetch origin main
  git reset --hard origin/main
else
  log "Remote main branch not found; initializing backup repo main branch."
  git checkout -B main
fi

mkdir -p sovereign
cp "$BACKUP_DIR"/sovereign/* sovereign/

git add sovereign/
git commit -m "backup: sovereign ${DATE}

db, avatars, plugin manifest, isolated plugin DBs"

git push -u "https://x-access-token:${BACKUP_GITHUB_TOKEN}@github.com/${BACKUP_GITHUB_REPO}.git" HEAD:main

# ── 6. Prune old backups ──────────────────────────────────────────────────────
log "Pruning backups older than ${RETENTION_DAYS} days..."

CUTOFF=$(date -u -d "${RETENTION_DAYS} days ago" +%s 2>/dev/null \
  || date -u -v-${RETENTION_DAYS}d +%s)

PRUNED=0
for f in sovereign/*-????????-??????.*; do
  [[ -f "$f" ]] || continue
  file_date=$(basename "$f" | grep -oP '\d{8}-\d{6}' || true)
  [[ -z "$file_date" ]] && continue
  file_ts=$(date -u -d "${file_date:0:8} ${file_date:9:2}:${file_date:11:2}:${file_date:13:2}" +%s 2>/dev/null \
    || date -u -j -f "%Y%m%d-%H%M%S" "$file_date" +%s 2>/dev/null || echo 0)
  if (( file_ts < CUTOFF )); then
    git rm -f "$f"
    PRUNED=$((PRUNED + 1))
  fi
done

if [[ "$PRUNED" -gt 0 ]]; then
  git commit -m "prune: remove ${PRUNED} backup file(s) older than ${RETENTION_DAYS} days"
  git push "https://x-access-token:${BACKUP_GITHUB_TOKEN}@github.com/${BACKUP_GITHUB_REPO}.git" HEAD:main
  log "  Pruned $PRUNED file(s)"
else
  log "  Nothing to prune"
fi

log "Backup complete."
