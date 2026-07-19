# sovereign-infra roadmap

This roadmap tracks implementation work for the `sovereign-infra` deployment
template. It is intentionally specific enough for AI agents to implement tasks
without relying on chat history.

Status legend:

- ✅ Done
- 📋 Planned
- ⛔ Blocked

## Current state

`sovereign-infra` is an operator-owned GitHub template for hosting Sovereign on
an Ubuntu VPS. It owns:

- Caddy reverse proxy config.
- VPS bootstrap and hardening.
- age-encrypted app `.env` files.
- GitHub Actions sync/deploy workflow.
- Daily encrypted backup scripts.

The platform repository (`sovereignfs/sovereign`) owns application code and
published Docker images. Operators deploy those images by pushing tags in their
own infra repository.

## Completed work

### ✅ INFRA-001 — Bootstrap prepares backup directory

**Goal:** Avoid permission failures when the backup installer runs as `deploy`.

**Implemented:**

- `bootstrap/setup.sh` creates `/opt/backups-repo`.
- `bootstrap/setup.sh` assigns `/opt/backups-repo` ownership to `deploy`.

**Verification:**

- `bash -n bootstrap/setup.sh`

### ✅ INFRA-002 — Backup installer handles existing and empty backup dirs

**Goal:** Make `scripts/install-backup-cron.sh` safe on fresh and already
provisioned VPS instances.

**Implemented:**

- Adds a deterministic `PATH` for non-interactive execution.
- Supports `BACKUP_REPO_DIR`, defaulting to `/opt/backups-repo`.
- Creates the backup repo directory when possible.
- Fails with explicit ownership repair commands when the directory is not
  writable by `deploy`.
- Rejects non-empty, non-git backup directories instead of cloning over them.
- Clones the configured backup repository into the backup directory.
- Registers cron with explicit `PATH` and `BACKUP_REPO_DIR`.

**Verification:**

- `bash -n scripts/install-backup-cron.sh`

### ✅ INFRA-003 — Automatic backup supports empty remote repositories

**Goal:** Make the documented "create a private empty backup repo" flow work.

**Implemented:**

- `scripts/backup-sovereign.sh` supports an empty remote with no `main` branch.
- First successful backup initializes local `main` and pushes `HEAD:main`.
- Later backups fetch and reset to `origin/main` before adding new artifacts.
- Script fails clearly if `/opt/backups-repo` was not cloned first.
- Script uses deterministic `PATH` for cron.

**Verification:**

- `bash -n scripts/backup-sovereign.sh`
- Local simulation: clone an empty bare repo, create initial backup commit, and
  push `HEAD:main`.

### ✅ INFRA-004 — Restore script accepts configurable backup repo path

**Goal:** Keep restore behavior aligned with backup installer and backup script.

**Implemented:**

- `scripts/restore-sovereign.sh` uses deterministic `PATH`.
- `scripts/restore-sovereign.sh` supports `BACKUP_REPO_DIR`, defaulting to
  `/opt/backups-repo`.

**Verification:**

- `bash -n scripts/restore-sovereign.sh`

### ✅ INFRA-005 — Backup setup documentation clarified

**Goal:** Make automatic backup setup steps explicit for operators.

**Implemented:**

- README explains that `bootstrap/setup.sh` does not enable backups.
- README explains that bootstrap only prepares `/opt/backups-repo`.
- README documents the manual `deploy` step:
  `./scripts/install-backup-cron.sh`.
- README states that the backup installer must run after `.env.enc` has been
  pushed and CI has installed `/opt/apps/sovereign/.env`.
- README documents repair commands for older servers where `/opt/backups-repo`
  does not exist or is root-owned.
- README states that empty backup repos are supported.
- README documents cron `PATH` behavior for `age`.

**Verification:**

- `pnpm exec prettier --check README.md`

### ✅ INFRA-011 — env.yml-driven encrypted environment generation

**Goal:** Replace manual `.env` editing with a repeatable local generator that
renders `apps/sovereign/.env` from the latest upstream Sovereign `.env.example`
plus operator-owned credentials in a git-ignored `env.yml`, then encrypts it to
`apps/sovereign/.env.enc`.

**Implemented:**

- `scripts/generate-env.js` (Node ESM, `js-yaml` dependency —
  `package.json`/`package-lock.json` added, `node_modules/` git ignored).
  Replaces `scripts/fetch-env-example.sh` (removed — its fetch-and-splice
  behavior was absorbed here rather than kept as a second, divergent path)
  and reuses `scripts/encrypt-env.sh` as-is via `execFileSync`, with
  `AGE_PUBLIC_KEY` passed through its environment and never logged.
- `env.example.yml` — committed template covering every key
  `apps/sovereign/.env.example`'s deployment-overrides block and critical
  upstream keys need, required vs. optional clearly separated. Copy to
  `env.yml` (git ignored) and fill in real values.
- Command interface: `node scripts/generate-env.js <app>`, with `--env-file
<path>`, `--check` (validates without writing any file), and `--no-fetch`
  (skips the network fetch, renders from the committed `.env.example`).
  Default mode fetches, renders, and encrypts.
- Rendering resolves a KEY appearing more than once (once in the upstream
  section with a local-dev default, again in the deployment-overrides block)
  by last-occurrence-wins value, emitted once at the first-occurrence
  position — a real duplicate-key bug found and fixed against the actual
  fetched upstream template during verification (e.g. `DB_DIALECT` was being
  emitted twice: `sqlite` then `postgres`).
- Two-layer validation: an explicit `REQUIRED_KEYS` list (not inferred from
  blank/placeholder heuristics, since some upstream keys are blank-but-
  optional, e.g. `SMTP_USER`/`SMTP_PASS`) plus a generic scan for leftover
  `YOUR_*`/`changeme` placeholder tokens in any active line, catching keys not
  on the explicit list too (e.g. `SMTP_FROM`'s shipped placeholder default).
- README: "Environment setup", "Secrets Management" (Encrypt a `.env` →
  First-time setup, Rotate a secret, Sync `.env.example`), and the
  invite-only rotation snippet rewritten to the `env.yml` + `generate-env.js`
  workflow. Prerequisites now lists Node.js ≥18.

**Verification:**

- `env.yml` is ignored by git; `apps/sovereign/.env` remains ignored;
  `apps/sovereign/.env.enc` is not ignored.
- `node scripts/generate-env.js sovereign --check --no-fetch` fails clearly
  (missing-required-values and unresolved-placeholder lists, by name only,
  never values) against an incomplete `env.yml`, and passes against a
  complete one.
- Full run (fetch + render + encrypt) against a complete test `env.yml` and a
  real generated age keypair: `.env` and `.env.enc` produced, decrypting
  `.env.enc` reproduces `.env` byte-for-byte, no duplicate keys, no leftover
  placeholders, no secret values printed to stdout.
- `bash -n scripts/*.sh bootstrap/setup.sh configure.sh` passes, and so does a
  `prettier --check` run over `README.md`, `roadmap.md`, `scripts/generate-env.js`,
  `env.example.yml`, and `package.json`.

### ✅ INFRA-012 — Build-and-deploy path for private plugins

**Goal:** Support deploying a sovereign-runtime image with private-repo
plugins baked in, without publishing anything to a registry, and without
disturbing the default published-image path for operators who don't need it.

**Implemented:**

- `.github/workflows/sync.yml`'s `sync` job gains a `detect` step
  (`has_custom_plugins` output) that checks for `sovereign.plugins.json` at
  the repo root.
- `deploy` (published image) now runs only when that file is absent; a new
  `deploy-custom` job runs only when it's present — mutually exclusive on
  the same `v*` tag push, both gated behind `needs: sync`.
- `deploy-custom` clones `sovereignfs/sovereign` at the pushed tag, overlays
  this repo's `sovereign.plugins.json`, and runs
  `docker buildx build --secret id=plugin_tokens,src=<tokens-file>` in the
  Actions runner (far better resourced than the VPS) — depends on the
  BuildKit secret **file** mount added to `sovereignfs/sovereign`'s own
  `Dockerfile`, which holds arbitrary `VAR=value` lines rather than a single
  named variable. Each plugin can declare its own `tokenEnv` name — no shared
  token, no cap on private plugin count.
- The token values live in `apps/_plugin-tokens/.env.enc`, encrypted with the
  same age pipeline as every other app's secrets (`./scripts/encrypt-env.sh
_plugin-tokens`) — no separate GitHub Actions secret needed, it rides on
  `AGE_PRIVATE_KEY`. Unlike every other `apps/*/.env.enc`, the `sync` job's
  decrypt-and-bundle loop explicitly skips it (mirroring the existing
  `_template` skip) so it's never installed on the VPS; `deploy-custom`
  decrypts it independently, right before the build, and discards it after.
- No registry involved: the built image is `docker save`d, shipped to the
  VPS over SSH (`appleboy/scp-action`), and `docker load`ed there. Only
  `sovereign-runtime` is ever custom-built — `sovereign-auth` doesn't compose
  plugins, so it always pulls the published image regardless of path.
- The loaded image is wired in via a new `docker-compose.custom-image.yml`
  written on the VPS — deliberately a different filename from this repo's
  pre-existing `docker-compose.override.yml` (the compose-gap workaround for
  env vars missing from the upstream compose file), since the two serve
  unrelated purposes and must be able to coexist. `deploy-custom` still
  copies and chains `docker-compose.override.yml` when present, exactly like
  `deploy` does.
- The `sync` job's secret-rotation restart step and the `deploy` job's
  published-image path both account for a `docker-compose.custom-image.yml`
  possibly left on disk by a prior custom deploy (chained into `COMPOSE_FILE`
  on restart; removed on fallback to the published-image path).
- README: rewrote the CI/CD pipeline diagram for both paths and added a new
  "Installing private plugins" section covering the `sovereign.plugins.json`
  shape, the per-plugin `tokenEnv` convention, the `apps/_plugin-tokens/.env`
  workflow, and caveats (build cost, no registry, why the mechanism exists at
  all — `sovereignfs/sovereign`'s own Dockerfile needs an explicit BuildKit
  secret, which a plain `docker compose up --build` doesn't pass through). The
  GitHub Actions secrets table stays at four entries — no new secret added.
- `apps/_plugin-tokens/.env.example` — committed template for the token file,
  following the same copy-fill-encrypt pattern as `apps/sovereign/.env.example`.

**Verification:**

- `.github/workflows/sync.yml` parses as valid YAML (`js-yaml`) and passes
  `prettier --check`.
- Manually traced both `if:` conditions against `needs.sync.outputs.has_custom_plugins`
  to confirm `deploy` and `deploy-custom` are mutually exclusive for every
  `v*` tag push.
- Not yet verified against a real GitHub Actions run — in particular,
  `appleboy/scp-action`'s `strip_components: 1` behavior on the shipped
  tarball needs confirming on first real trigger.

## Planned work

### 📋 INFRA-006 — Canonical backup repository layout

**Goal:** Replace the current flat backup file layout with one stable directory
layout that cron backup, tag-triggered backup, manual restore, and future
tag-triggered restore all use.

**Current layout:**

```text
sovereign/
  db-20260706-030000.sql.gz.enc
  avatars-20260706-030000.tar.gz.enc
  plugins-manifest-20260706-030000.json.enc
  plugin-dbs-20260706-030000.tar.gz.enc
```

**Problem:**

Restore reconstructs expected file paths from the date argument. That works for
cron timestamps, but it does not work cleanly for tag-triggered restore IDs such
as `rst-v2026-07-06.1`, and it gives restore no manifest to verify before
stopping containers.

**Canonical layout:**

```text
sovereign/
  backups/
    cron-20260706-030000/
      db.sql.gz.enc
      avatars.tar.gz.enc
      plugins-manifest.json.enc
      plugin-dbs.tar.gz.enc
      manifest.json
    bk-v2026-07-06.1/
      db.sql.gz.enc
      avatars.tar.gz.enc
      plugins-manifest.json.enc
      plugin-dbs.tar.gz.enc
      manifest.json
```

`manifest.json` is intentionally plaintext metadata. It must not contain secrets
or raw env values. All data-bearing artifacts remain age-encrypted.

**Backup ID rules:**

- Cron backup ID: `cron-YYYYMMDD-HHMMSS`
- Tag backup ID: exact backup tag, for example `bk-v2026-07-06.1`
- Restore input should resolve by backup ID, not by reconstructing artifact
  filenames.

**Manifest schema:**

```json
{
  "schemaVersion": 1,
  "backupId": "bk-v2026-07-06.1",
  "createdAt": "2026-07-06T03:00:00Z",
  "source": "tag",
  "sovereignVersion": "v0.9.10",
  "components": [
    {
      "name": "postgres",
      "file": "db.sql.gz.enc",
      "required": true,
      "sha256": "..."
    },
    {
      "name": "avatars",
      "file": "avatars.tar.gz.enc",
      "required": false,
      "sha256": "..."
    },
    {
      "name": "pluginsManifest",
      "file": "plugins-manifest.json.enc",
      "required": false,
      "sha256": "..."
    },
    {
      "name": "pluginDbs",
      "file": "plugin-dbs.tar.gz.enc",
      "required": false,
      "sha256": "..."
    }
  ]
}
```

**Implementation notes:**

- Update `scripts/backup-sovereign.sh` to accept an optional `BACKUP_ID`.
- When `BACKUP_ID` is unset, generate `cron-YYYYMMDD-HHMMSS`.
- Stage artifacts under `$BACKUP_DIR/sovereign/backups/$BACKUP_ID/`.
- Use fixed artifact names inside each backup directory.
- Generate `manifest.json` after artifacts are written and checksums are known.
- Commit the whole `sovereign/backups/$BACKUP_ID/` directory.
- Prune by backup directory, not by individual files.
- Keep legacy flat-layout restore support temporarily for existing backup repos.
- Do not produce both flat and canonical layouts for new backups.

**Dependencies:**

- INFRA-001 through INFRA-005.

**Deliverables:**

- Updated `scripts/backup-sovereign.sh`.
- Updated `scripts/restore-sovereign.sh` with backup ID resolution.
- README section documenting the canonical backup repo layout.
- Roadmap update if compatibility behavior changes.

**Verification checklist:**

- Cron backup creates `sovereign/backups/cron-*`.
- Backup directory contains fixed artifact names.
- `manifest.json` lists every artifact that exists.
- Manifest SHA-256 values match artifact contents.
- Restore by backup ID validates manifest before stopping containers.
- Restore by legacy date still works or prints a clear migration/deprecation
  message.
- Retention removes complete backup directories, never partial artifacts.

### 📋 INFRA-007 — Tag-triggered backup workflow

**Goal:** Add a secondary, operator-triggered backup path using Git tags in the
operator's `sovereign-infra` repository. This exists alongside the daily cron
backup path; it does not replace cron.

**Tag format:**

- Backup tag: `bk-vYYYY-MM-DD.N`
- Example: `bk-v2026-07-06.1`
- Use ISO date order. Do not use `YYYY-DD-MM`.

**Trigger behavior:**

- Pushing a `bk-v*` tag to the operator infra repo starts a GitHub Actions job.
- The job validates the tag with a strict regex:
  `^bk-v[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$`.
- The job SSHes to the VPS as `deploy`.
- The job runs a local backup command on the VPS.
- The job commits and pushes the encrypted backup artifacts to the configured
  backup git repository.
- The job writes a GitHub Actions step summary with:
  - backup ID
  - backup repo
  - backup commit SHA
  - artifact list
  - total size
  - VPS hostname
  - UTC timestamp

**Implementation notes:**

- Add `.github/workflows/backup.yml`.
- Reuse existing GitHub secrets:
  - `VPS_HOST`
  - `VPS_USER`
  - `VPS_SSH_KEY`
- Backup repo credentials should stay in `/opt/apps/sovereign/.env` initially:
  - `BACKUP_GITHUB_TOKEN`
  - `BACKUP_GITHUB_REPO`
  - `AGE_PUBLIC_KEY`
- The workflow should call:
  `BACKUP_ID="$GITHUB_REF_NAME" /opt/infra/scripts/backup-sovereign.sh`.
- The backup script must write the canonical
  `sovereign/backups/<backup-id>/` directory from INFRA-006.
- The workflow must not require `sudo`.
- The workflow must not commit any plaintext `.env` file.

**Dependencies:**

- INFRA-006.
- Existing SSH deploy workflow must be configured and working.
- `/opt/apps/sovereign/.env` must contain backup config.

**Deliverables:**

- `.github/workflows/backup.yml`
- README section: "On-demand backup by tag"
- Troubleshooting notes for invalid tag, missing backup env, missing SSH secret,
  and empty backup repo initialization.

**Verification checklist:**

- Invalid backup tag is rejected before SSH.
- Valid backup tag runs against a test VPS or mocked SSH command.
- Empty backup repo gets initialized successfully.
- Existing backup repo gets a new commit.
- Backup repo contains `sovereign/backups/<tag>/manifest.json`.
- Workflow summary includes backup commit SHA.
- Daily cron backup still works after this change.

### 📋 INFRA-008 — Tag-triggered restore workflow

**Goal:** Add a GitHub Actions restore workflow triggered by restore tags in the
operator infra repo.

**Tag format:**

- Restore tag: `rst-vYYYY-MM-DD.N`
- Example: `rst-v2026-07-06.1`
- Matching backup ID: replace `rst-` with `bk-`.
- Example: `rst-v2026-07-06.1` restores `bk-v2026-07-06.1`.

**Trigger behavior:**

- Pushing an `rst-v*` tag starts a restore workflow.
- The workflow validates the tag with strict regex:
  `^rst-v[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]+$`.
- The workflow derives the backup ID by replacing `rst-` with `bk-`.
- The workflow requires GitHub Actions environment approval before SSH.
- After approval, the job SSHes to the VPS as `deploy`.
- The job pulls the backup repo.
- The job verifies the selected backup exists.
- The job runs restore using the selected backup ID.
- The job writes a summary with restored backup ID, source commit SHA, and UTC
  completion time.

**Safety requirements:**

- Restore must be protected by a GitHub Actions environment such as
  `production-restore`.
- Restore must create a pre-restore safety backup before modifying data, unless
  an explicit documented override is introduced.
- Restore must stop `runtime` and `auth` before database replacement.
- Restore must not delete the backup repo clone.
- Restore must fail before modifying data when the backup manifest is missing or
  checksum validation fails.

**Implementation notes:**

- Add `.github/workflows/restore.yml`.
- Add `scripts/restore-by-id.sh <backup-id>` or extend
  `scripts/restore-sovereign.sh` to accept `--backup-id`.
- Restore must use the canonical `sovereign/backups/<backup-id>/` layout from
  INFRA-006. Do not build tag-triggered restore on the legacy flat dated files.

**Dependencies:**

- INFRA-006 is a blocker.
- INFRA-007 should land first so matching `bk-*` backup IDs can be created by
  tag.
- Existing restore script must be tested manually before wiring the workflow.

**Deliverables:**

- `.github/workflows/restore.yml`
- Restore environment documented in README.
- Restore tag workflow documented in README.
- Restore safety checklist documented in README.

**Verification checklist:**

- Invalid restore tag is rejected before approval.
- Restore job waits for environment approval.
- Missing backup ID fails before stopping containers.
- Checksum mismatch fails before stopping containers.
- Successful restore restarts containers.
- Workflow summary reports restored backup ID and result.

### 📋 INFRA-009 — Backup retention policy configuration

**Goal:** Make backup retention explicit and configurable for both cron and
tag-triggered backups.

**Current behavior:**

- `scripts/backup-sovereign.sh` prunes files older than 30 days.
- Retention is hardcoded with `RETENTION_DAYS=30`.

**Target behavior:**

- Add `BACKUP_RETENTION_DAYS`, defaulting to `30`.
- Cron backups follow retention automatically.
- Tag-triggered backups should be retained by default unless
  `BACKUP_PRUNE_TAGGED=true` is set.
- README documents how to choose `30`, `60`, `90`, or no automatic pruning.

**Dependencies:**

- INFRA-006.

**Deliverables:**

- Updated `.env.example`.
- Updated backup script retention logic.
- README retention documentation.

**Verification checklist:**

- `BACKUP_RETENTION_DAYS=30` prunes old cron backups.
- `BACKUP_RETENTION_DAYS=0` or `never` disables pruning.
- Tagged backups are preserved by default.
- Prune commit message reports deleted backup IDs.

### 📋 INFRA-010 — Move artifact collection to platform CLI when available

**Goal:** Eventually replace infra-specific artifact collection with the
platform-owned `sv backup --local-only` and `sv restore --local-only` commands.

**Rationale:**

`sovereign-infra` should orchestrate SSH, GitHub Actions, and backup repo
push/pull. The platform CLI should own which Sovereign artifacts must be backed
up and restored.

**Target backup command:**

```bash
sv backup --local-only --output /tmp/sovereign-backup
```

**Target restore command:**

```bash
sv restore --local-only --input /tmp/sovereign-backup
```

**Dependencies:**

- Platform CLI support in `sovereignfs/sovereign`.
- Compatibility with the backup manifest design from INFRA-006.

**Deliverables:**

- Update `scripts/backup-sovereign.sh` to call `sv backup --local-only` when
  available.
- Update restore script to call `sv restore --local-only` when available.
- Keep fallback behavior or document the minimum platform version required.

**Verification checklist:**

- Infra backup works with a platform release that has `sv backup --local-only`.
- Infra backup fails clearly with older platform releases if no fallback is kept.
- README documents the minimum Sovereign version for CLI-backed backups.

## Agent implementation rules

- Keep cron backups and tag-triggered backups separate until both are verified.
- Do not remove the existing daily cron path while adding tag-triggered flows.
- Do not commit plaintext `.env` files.
- Do not commit `env.yml`.
- Do not require root for scheduled backup or restore operations.
- Restore changes must fail before stopping containers if the requested backup
  cannot be verified.
- Prefer small scripts over embedding large shell programs directly in workflow
  YAML.
- Update README and this roadmap in the same change as implementation.
- Run at minimum:
  - `bash -n scripts/*.sh bootstrap/setup.sh configure.sh`
  - `pnpm exec prettier --check README.md roadmap.md`
