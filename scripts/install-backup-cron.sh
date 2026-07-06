#!/usr/bin/env bash
# scripts/install-backup-cron.sh
#
# Run once on the VPS (as the deploy user) to:
#   1. Install age (if not already installed)
#   2. Clone your backup repo to /opt/backups-repo
#   3. Register the daily cron job
#
# The backup script runs directly from the infra repo — no copy needed.
# Changes to scripts/backup-sovereign.sh take effect after the next `git pull`
# in /opt/infra (which happens automatically on every infra push via sync.yml).
#
# Prerequisites:
#   - /opt/apps/sovereign/.env exists with BACKUP_GITHUB_TOKEN, BACKUP_GITHUB_REPO,
#     and AGE_PUBLIC_KEY set
#   - Your backup repo exists on GitHub (private, empty is fine)

set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

REPO_DIR="${BACKUP_REPO_DIR:-/opt/backups-repo}"

# ── Load env ──────────────────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
source /opt/apps/sovereign/.env
set +a

if [[ -z "${BACKUP_GITHUB_TOKEN:-}" ]]; then
  echo "Error: BACKUP_GITHUB_TOKEN is not set in /opt/apps/sovereign/.env" >&2
  exit 1
fi

if [[ -z "${BACKUP_GITHUB_REPO:-}" ]]; then
  echo "Error: BACKUP_GITHUB_REPO is not set in /opt/apps/sovereign/.env" >&2
  echo "  Set it to owner/repo, e.g. myorg/sovereign-backups" >&2
  exit 1
fi

if [[ -z "${AGE_PUBLIC_KEY:-}" ]]; then
  echo "Error: AGE_PUBLIC_KEY is not set in /opt/apps/sovereign/.env" >&2
  exit 1
fi

# ── Install age ───────────────────────────────────────────────────────────────
if ! command -v age &>/dev/null; then
  echo "==> Installing age..."
  curl -fsSL https://github.com/FiloSottile/age/releases/download/v1.2.0/age-v1.2.0-linux-amd64.tar.gz \
    | sudo tar xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen
  echo "age $(age --version) installed"
else
  echo "age already installed: $(age --version)"
fi

# ── Clone backup repo ─────────────────────────────────────────────────────────
if [[ ! -d "$REPO_DIR" ]]; then
  if ! mkdir -p "$REPO_DIR" 2>/dev/null; then
    echo "Error: cannot create $REPO_DIR as $(id -un)." >&2
    echo "Create it as root, then rerun this script:" >&2
    echo "  install -d -o $(id -un) -g $(id -gn) $REPO_DIR" >&2
    exit 1
  fi
fi

if [[ ! -w "$REPO_DIR" ]]; then
  echo "Error: $REPO_DIR is not writable by $(id -un)." >&2
  echo "Fix ownership as root, then rerun this script:" >&2
  echo "  chown -R $(id -un):$(id -gn) $REPO_DIR" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  if find "$REPO_DIR" -mindepth 1 -maxdepth 1 | grep -q .; then
    echo "Error: $REPO_DIR exists but is not empty and is not a git repo." >&2
    echo "Move its contents aside or set BACKUP_REPO_DIR to another path." >&2
    exit 1
  fi
  echo "==> Cloning ${BACKUP_GITHUB_REPO}..."
  git clone \
    "https://x-access-token:${BACKUP_GITHUB_TOKEN}@github.com/${BACKUP_GITHUB_REPO}.git" \
    "$REPO_DIR"
else
  echo "$REPO_DIR already contains a git repo — skipping clone"
fi

# ── Set up log file ───────────────────────────────────────────────────────────
# Logs go to ~/logs/ — the deploy user owns it, no root access needed.
mkdir -p "$HOME/logs"
touch "$HOME/logs/sovereign-backup.log"
echo "==> Log file: $HOME/logs/sovereign-backup.log"

# ── Register cron job ─────────────────────────────────────────────────────────
# The script runs directly from the infra repo — updates to it take effect
# automatically after every git pull (no manual reinstall required).
SCRIPT_PATH="/opt/infra/scripts/backup-sovereign.sh"
LOG_PATH="$HOME/logs/sovereign-backup.log"
CRON_LINE="0 3 * * * PATH=/usr/local/bin:/usr/bin:/bin BACKUP_REPO_DIR=$REPO_DIR $SCRIPT_PATH >> $LOG_PATH 2>&1"

if crontab -l 2>/dev/null | grep -qF "backup-sovereign.sh"; then
  echo "==> Cron job already registered — skipping"
else
  echo "==> Registering daily 03:00 UTC cron job..."
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "    $CRON_LINE"
fi

echo ""
echo "==> Done. Test the backup now with:"
echo "    $SCRIPT_PATH"
echo ""
echo "    Logs: $LOG_PATH"
