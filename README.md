# sovereign-infra

**Template for self-hosting [Sovereign](https://github.com/sovereignfs/sovereign) on a VPS.**

Fork or use as a GitHub template. Run `./configure.sh` to set your domains, bootstrap
a VPS, push a version tag — CI handles the rest.

**Stack:** Caddy (auto-TLS) · Docker Compose · age-encrypted secrets · GitHub Actions CI/CD.
No Terraform, no Ansible, no managed cloud required. Any Ubuntu 24.04 VPS works.

---

## Quick start

```
1. Fork / use as template → your-org/sovereign-infra
2. Clone locally and run ./configure.sh
3. Commit the domain config and push to main
4. Provision a VPS and run bootstrap/setup.sh
5. Encrypt your .env and push to main (CI installs it)
6. Push a version tag → CI deploys Sovereign
```

Full walkthrough below.

---

## Two-repo model

| Repo                    | Role         | Trigger                | What it does                                |
| ----------------------- | ------------ | ---------------------- | ------------------------------------------- |
| `sovereignfs/sovereign` | **Provider** | push `v*` tag          | builds Docker images, pushes to GHCR        |
| `<you>/sovereign-infra` | **Operator** | push any tag           | decrypts + installs app envs, reloads Caddy |
| `<you>/sovereign-infra` | **Operator** | push matching `v*` tag | verifies GHCR images exist, deploys to VPS  |

Sovereign publishes images when tagged. You deploy those images by pushing the same tag here.
They are independent — see `docs/sovereign-deploy-workflow.md` for the full model.

---

## Repository structure

```
.github/workflows/
  sync.yml        # any tag → sync (secrets + Caddy); v* tag → also deploy (needs: sync)

bootstrap/
  setup.sh        # one-time VPS provisioning (run as root)

caddy/
  Caddyfile       # imports conf.d/*.caddy — do not add vhosts here directly
  conf.d/
    sovereign.caddy           # your Sovereign vhosts (configured by ./configure.sh)
    _template.caddy.example   # copy this when adding a new app
  docker-compose.yml

apps/
  sovereign/
    .env.example                        # deployment skeleton — fill in and encrypt
    docker-compose.override.yml.example # workaround for upstream compose gaps
    # No docker-compose.yml — fetched from the sovereign release at deploy time
  _template/                            # copy this when adding a new non-sovereign app
    docker-compose.yml
    .env.example

scripts/
  configure.sh            # one-time domain setup (run locally)
  generate-env.js         # env.yml + latest upstream .env.example → .env, .env.enc
  encrypt-env.sh          # encrypt apps/<name>/.env → .env.enc (called by generate-env.js)
  decrypt-env.sh          # decrypt .env.enc → /opt/apps/<name>/.env
  backup-sovereign.sh     # daily backup (run from cron on VPS)
  restore-sovereign.sh    # restore from a dated backup
  install-backup-cron.sh  # one-time backup cron + repo setup on VPS
  logs.sh                 # convenience docker logs wrapper

env.example.yml  # template for env.yml — copy it, fill in real values, never commit the copy

docs/
  ports.md                      # port registry — prevents collisions
  sovereign-deploy-workflow.md  # two-repo model + deploy steps
```

### VPS directory layout

```
/opt/infra/                         ← git clone of this repo
/opt/apps/
  sovereign/
    docker-compose.prod.yml         ← fetched from sovereignfs/sovereign on each deploy
    docker-compose.postgres.yml     ← fetched from sovereignfs/sovereign on each deploy
    docker-compose.override.yml     ← copied from infra repo if present (optional)
    .env                            ← NOT in git; decrypted by CI from .env.enc
    .deploy-version                 ← currently deployed tag
  myapp/                            ← example future app (infra-managed compose)
    docker-compose.yml              ← symlink → /opt/infra/apps/myapp/docker-compose.yml
    .env
/opt/backups-repo/                  ← clone of your backup repo
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Domain configuration](#2-domain-configuration)
3. [Secrets setup (age)](#3-secrets-setup-age)
4. [DNS setup](#4-dns-setup)
5. [VPS bootstrap](#5-vps-bootstrap)
6. [Caddy — reverse proxy](#6-caddy--reverse-proxy)
7. [Sovereign deployment](#7-sovereign-deployment)
8. [CI/CD pipeline](#8-cicd-pipeline)
9. [Adding a new app](#9-adding-a-new-app)
10. [Rollback](#10-rollback)
11. [Backups](#11-backups)
12. [Secrets management](#12-secrets-management)
13. [Reference](#13-reference)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Prerequisites

**Local machine:**

- `git`
- `age` — `brew install age` (macOS) / `apt install age` (Ubuntu)
- Node.js ≥18 — for `scripts/generate-env.js` (`npm install` once, see ["Secrets
  Management"](#12-secrets-management))
- SSH key pair for CI (generated below)

**VPS:**

- Ubuntu 24.04 LTS (any provider: Hetzner, DigitalOcean, Linode, etc.)
- At least 1 GB RAM, 1 vCPU — Sovereign runs comfortably on a $5–6/month instance
- A domain name with DNS you control

**GitHub:**

- This repo forked or used as template (must be **private** — it will contain `.env.enc` files)
- A separate private repo for encrypted backups (created in step 11)

---

## 2. Domain configuration

After forking, run `./configure.sh` once to stamp your domains into the config files:

```bash
./configure.sh
```

It prompts for three values:

| Prompt         | Example            | Used for                                    |
| -------------- | ------------------ | ------------------------------------------- |
| Runtime domain | `example.com`      | Main app URL, WebAuthn origin               |
| Auth domain    | `auth.example.com` | Auth server URL, WebAuthn origin            |
| Root domain    | `example.com`      | WebAuthn RP_ID, cookie domain, email sender |

The script edits `caddy/conf.d/sovereign.caddy`, `apps/sovereign/.env.example`, and
`docs/ports.md` in place. Review the diff, then commit:

```bash
git diff
git add caddy/conf.d/sovereign.caddy apps/sovereign/.env.example docs/ports.md
git commit -m "config: set domain to example.com"
git push origin main
```

---

## 3. Secrets setup (age)

Secrets are encrypted with [age](https://github.com/FiloSottile/age) before being committed.
The age private key never leaves your local machine (and GitHub Actions secrets).

### One-time key setup

```bash
# Generate your age keypair
age-keygen -o ~/.age/key.txt
# Printed: Public key: age1...

# Export the public key for use in encrypt-env.sh
echo 'export AGE_PUBLIC_KEY=age1...' >> ~/.zshrc
source ~/.zshrc
```

Save `~/.age/key.txt` to your password manager immediately. It contains both keys. This is
the only copy.

### Generate a CI SSH keypair

```bash
ssh-keygen -t ed25519 -C "sovereign-ci-deploy" -f ~/.ssh/sovereign_ci_deploy
# ~/.ssh/sovereign_ci_deploy      ← private key → GitHub secret VPS_SSH_KEY
# ~/.ssh/sovereign_ci_deploy.pub  ← public key  → pasted during bootstrap
```

---

## 4. DNS setup

Add two A records pointing to your VPS IP (both use the same IP; Caddy routes by hostname):

| Type | Name               | Value      |
| ---- | ------------------ | ---------- |
| A    | `example.com`      | `<VPS IP>` |
| A    | `auth.example.com` | `<VPS IP>` |

Verify propagation before continuing (the VPS must be reachable at these names for
Caddy to provision Let's Encrypt certificates):

```bash
dig +short example.com
dig +short auth.example.com
```

---

## 5. VPS Bootstrap

Run once on a fresh Ubuntu 24.04 VPS as root.

### Step 1 — Clone the infra repo onto the VPS

Create a fine-grained GitHub PAT with **Contents → Read** access to this repo,
then:

```bash
ssh root@<VPS IP>
apt-get install -y git
git clone https://x-access-token:<PAT>@github.com/<your-org>/sovereign-infra.git /opt/infra
```

The PAT is embedded in the remote URL so future `git pull` calls work without
re-entering credentials. To rotate it later:

```bash
sudo -u deploy git -C /opt/infra remote set-url origin \
  https://x-access-token:<NEW_PAT>@github.com/<your-org>/sovereign-infra.git
```

### Step 2 — Run the bootstrap script

```bash
bash /opt/infra/bootstrap/setup.sh
```

The script pauses to ask for the CI public key — paste the contents of
`~/.ssh/sovereign_ci_deploy.pub` (from your local machine), then signal end-of-input:

```
# Paste the key, press Enter to go to a new line, then Ctrl+D.
# If Ctrl+D seems to do nothing, press Enter first — the terminal needs a
# newline after the pasted content before it will accept the EOF signal.
```

The script handles: Docker (with log rotation), jq, deploy user creation, SSH hardening
(password auth disabled), firewall (22/80/443 only), logrotate, and directory setup.

**Important:** the script prints the deploy user's password at the end — save it in your
password manager immediately. This password is only for emergency VPS web-console access.
Normal SSH requires the key.

**If you missed the password** (e.g. it scrolled past), reset it now while still logged
in as root:

```bash
DEPLOY_PASS=$(openssl rand -base64 24 | tr -d '/+=')
echo "deploy:$DEPLOY_PASS" | chpasswd
echo "New deploy password: $DEPLOY_PASS"
```

---

## 6. Caddy — Reverse Proxy

Caddy runs as a standalone Docker container with `network_mode: host`, so it can reach
any app on `localhost` without a shared Docker network.

### Structure

```caddy
# caddy/Caddyfile — imports per-app files; do not add vhosts here
(common_headers) {
    header {
        -Server
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}

import /etc/caddy/conf.d/*.caddy
```

```caddy
# caddy/conf.d/sovereign.caddy — configured by ./configure.sh
example.com {
    import common_headers
    reverse_proxy 127.0.0.1:4000 {
        flush_interval -1   # required for SSE (live notifications)
    }
}

auth.example.com {
    import common_headers
    reverse_proxy 127.0.0.1:4001
}
```

A bad block in one `.caddy` file never affects others. The sync workflow validates config
before reloading, so a broken push can't take down Caddy.

### Start Caddy

```bash
cd /opt/infra/caddy
docker compose up -d
docker logs caddy -f
# Watch for: "certificate obtained successfully" for each domain
```

### Reload after config changes

Config changes pushed to `main` are applied automatically by CI. To reload manually:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

---

## 7. Sovereign Deployment

### Environment setup

```bash
# Locally, in the infra repo:
cp env.example.yml env.yml   # git ignored — never commit this copy
nano env.yml                 # fill in all required values
node scripts/generate-env.js sovereign
git add apps/sovereign/.env.example apps/sovereign/.env.enc
git commit -m "secrets: sovereign initial"
git push origin main
# CI decrypts and installs /opt/apps/sovereign/.env on the VPS automatically
```

`generate-env.js` fetches the latest upstream `apps/sovereign/.env.example`, renders
`apps/sovereign/.env` from `env.yml`, and encrypts it to `apps/sovereign/.env.enc` — see
["Secrets Management"](#12-secrets-management) for the full workflow, options, and what to
do when validation fails.

Key points:

- `COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml` is set in `.env`
  so plain `docker compose` commands automatically use both files.
- `AUTH_WEBAUTHN_RP_ID` must be the bare registrable domain (e.g. `example.com`).
  Changing it after passkeys are registered invalidates all existing passkeys.
- `DATABASE_URL` and `AUTH_DATABASE_URL` are constructed by the Postgres overlay —
  do not set them directly.
- Postgres is not exposed on any host port — only reachable inside the Docker network.
  Backups use `docker exec`, not TCP.

### Compose override (recommended)

The upstream `docker-compose.prod.yml` is missing several env vars (passkeys, VAPID,
log level, notification transport). Activate the included override to fix this:

```bash
cp apps/sovereign/docker-compose.override.yml.example \
   apps/sovereign/docker-compose.override.yml
git add apps/sovereign/docker-compose.override.yml
git commit -m "config: enable compose override"
git push origin main
```

CI automatically includes the override file in the compose stack when it is present.
See `apps/sovereign/docker-compose.override.yml.example` for details.

### First deploy

```bash
git tag v0.9.10 && git push origin v0.9.10
```

CI verifies the GHCR images exist, fetches compose files from `sovereignfs/sovereign@v0.9.10`,
pulls images, and starts the stack. Watch progress in your repo's Actions tab.

Verify:

```bash
curl -s https://example.com/api/health
curl -s https://auth.example.com/api/health
```

Open `https://example.com`. The first user to register becomes admin.
After registering, lock registration:

```bash
# Locally:
nano env.yml   # set apps.sovereign.AUTH_INVITE_ONLY: 'true'
node scripts/generate-env.js sovereign
git add apps/sovereign/.env.enc && git commit -m "config: enable invite-only"
git push origin main
# Apply immediately:
ssh deploy@<VPS IP> "cd /opt/apps/sovereign && docker compose up -d"
```

---

## 8. CI/CD Pipeline

A single workflow file (`.github/workflows/sync.yml`) handles everything with a `sync`
job plus one of two deploy jobs, chosen automatically by whether `sovereign.plugins.json`
exists at the repo root:

```
Push any tag   e.g.  git tag caddy && git push origin caddy
    │
    ▼
Job 1 — sync (always runs)
    ├── Decrypt all apps/*/.env.enc (dynamic — no hardcoded app list)
    ├── Install each app's .env on VPS
    ├── git pull /opt/infra
    └── Validate + reload Caddy (zero-downtime)

Push v* tag, sovereign.plugins.json ABSENT  →  Job "deploy" (published image)
    Verify GHCR images exist for this tag
    SSH into VPS:
      curl docker-compose.prod.yml / .postgres.yml from sovereignfs/sovereign@vX.Y.Z
      Copy docker-compose.override.yml if present in infra repo (compose-gap workaround)
      docker compose pull && docker compose up -d
      docker image prune -f · echo vX.Y.Z > .deploy-version

Push v* tag, sovereign.plugins.json PRESENT  →  Job "deploy-custom" (private plugins)
    Decrypt apps/_plugin-tokens/.env.enc if present (age, same key as everything else)
    Clone sovereignfs/sovereign@vX.Y.Z, overlay this repo's sovereign.plugins.json
    docker buildx build --secret id=plugin_tokens,src=<decrypted-tokens-file> --load
    docker save | gzip → scp to VPS → docker load (no registry involved)
    SSH into VPS: copy docker-compose.override.yml if present, write
    docker-compose.custom-image.yml pointing runtime at the loaded image,
    pull only sovereign-auth (still published), docker compose up -d
```

If the GHCR images don't exist for that tag, both deploy jobs fail before touching the VPS —
the running version stays live either way. See ["Installing private
plugins"](#installing-private-plugins) below for the custom-image path in full.

### GitHub Actions secrets

Add these to your infra repo → Settings → Secrets and variables → Actions →
**Repository secrets** → New repository secret:

> These must be **repository secrets** (the "Variables" tab is for non-sensitive values
> and will not work for these).

| Secret            | Value                                                  |
| ----------------- | ------------------------------------------------------ |
| `VPS_HOST`        | VPS IP address                                         |
| `VPS_USER`        | `deploy`                                               |
| `VPS_SSH_KEY`     | Contents of `~/.ssh/sovereign_ci_deploy` (private key) |
| `AGE_PRIVATE_KEY` | Contents of `~/.age/key.txt` (age private key)         |

All four must exist before pushing any tag, otherwise the decrypt step fails immediately.
No extra GitHub secret is needed for private plugins — see below.

### Installing private plugins

By default this repo deploys sovereign exactly as `sovereignfs/sovereign` published it — no
build step, just a `docker compose pull`. To add a plugin from a private GitHub repo, commit a
`sovereign.plugins.json` at this repo's root:

```json
{
  "plugins": [
    {
      "id": "com.acme.crm",
      "repository": "https://github.com/acme/sovereign-crm",
      "tokenEnv": "ACME_CRM_PLUGIN_TOKEN"
    }
  ]
}
```

- `tokenEnv` can be any name you choose, and **each plugin can use a different one** — the
  platform Dockerfile mounts a build secret _file_ of arbitrary `VAR=value` lines, not a single
  named variable, so there's no cap and nothing to coordinate across plugins.
- Set the actual token values in `apps/_plugin-tokens/.env` — copy from
  `apps/_plugin-tokens/.env.example`, add one line per `tokenEnv` name, then encrypt it exactly
  like any other app's secrets:
  ```bash
  cp apps/_plugin-tokens/.env.example apps/_plugin-tokens/.env
  nano apps/_plugin-tokens/.env   # ACME_CRM_PLUGIN_TOKEN=ghp_xxx
  ./scripts/encrypt-env.sh _plugin-tokens
  git add apps/_plugin-tokens/.env.enc
  git commit -m "secrets: add plugin token for com.acme.crm"
  git push origin main
  ```
  This rides on the `AGE_PRIVATE_KEY` secret you already have — no new GitHub Actions secret to
  create. Unlike every other `apps/*/.env.enc`, this one is **never installed on the VPS**; the
  `sync` job explicitly skips it, and it's decrypted only inside `deploy-custom`, used to build
  the image, then discarded.
- A fine-grained GitHub PAT scoped to just that repository with **Contents: Read-only** is the
  least privilege that works. One PAT can also cover several repos under the same owner, in which
  case those plugins can share a `tokenEnv`.
- Public plugins can go in the same file with no `tokenEnv` field at all.

Once `sovereign.plugins.json` exists, **every subsequent `v*` tag automatically takes the
custom-build path** — `deploy-custom` instead of `deploy`. Nothing else changes: same tag
command (`git tag v0.9.10 && git push origin v0.9.10`), same `.deploy-version` tracking
(suffixed `-custom` so `cat /opt/apps/sovereign/.deploy-version` tells you which path last ran).

The existing `docker-compose.override.yml` compose-gap workaround (see [Compose
override](#compose-override-recommended) above) still applies on the custom-build path — it's
copied from the infra repo and chained into `COMPOSE_FILE` alongside the new
`docker-compose.custom-image.yml`, which is reserved for the runtime-image redirect and always
distinct from the override file.

To go back to the published-image path, delete `sovereign.plugins.json` and push a new tag — the
next deploy fetches sovereign's own compose files fresh and removes any leftover
`docker-compose.custom-image.yml` from a previous custom deploy.

**Only `sovereign-runtime` is ever custom-built** — `sovereign-auth` doesn't compose plugins at
all, so it always pulls `sovereignfs`'s published image regardless of which path is active.

**Caveats:**

- The build runs in the GitHub Actions runner, not the VPS, and never touches a registry — the
  image is `docker save`d, shipped to the VPS over SSH, and `docker load`ed there. Expect the
  `deploy-custom` job to take noticeably longer than a plain image pull (a full monorepo build
  plus a several-hundred-MB transfer), and expect it to use more Actions minutes.
- This whole mechanism exists because of a real gap in `sovereignfs/sovereign`'s own Dockerfile:
  a plain `docker compose up --build` does **not** pass a build secret through on its own —
  private-repo plugin cloning needs an explicit
  `docker buildx build --secret id=plugin_tokens,src=<tokens-file>` invocation, which is exactly
  what `deploy-custom` runs on your behalf.

### Deploying a new version

```bash
# Confirm the sovereign release has published GHCR images first:
docker manifest inspect ghcr.io/sovereignfs/sovereign-runtime:v0.9.10

# Tag the infra repo at the same version:
git tag v0.9.10 && git push origin v0.9.10
```

### What version is currently deployed

```bash
cat /opt/apps/sovereign/.deploy-version
```

---

## 9. Adding a New App

Say you want to host `myapp.example.com` on port `5000`.

**1. Pick a port** — open `docs/ports.md`, pick the next free port, add a row.

**2. Add the Caddy vhost**

```bash
cp caddy/conf.d/_template.caddy.example caddy/conf.d/myapp.caddy
# Edit: set domain and port. Add flush_interval -1 for SSE apps.
```

**3. Add the app stack**

```bash
cp -r apps/_template apps/myapp
# Edit docker-compose.yml: image, port, env vars
# Edit .env.example: list every variable the app needs
```

**4. Set up secrets**

```bash
cp apps/myapp/.env.example apps/myapp/.env
nano apps/myapp/.env
./scripts/encrypt-env.sh myapp
```

**5. Push to main**

```bash
git add caddy/conf.d/myapp.caddy apps/myapp/ docs/ports.md
git commit -m "feat: add myapp"
git push origin main
# CI reloads Caddy — TLS provisioned automatically
```

**6. First start (VPS, one time)**

```bash
ssh deploy@<VPS IP>
mkdir -p /opt/apps/myapp
ln -sf /opt/infra/apps/myapp/docker-compose.yml /opt/apps/myapp/docker-compose.yml
cd /opt/apps/myapp
APP_VERSION=v1.0.0 docker compose pull
APP_VERSION=v1.0.0 docker compose up -d
```

**7. Add DNS record**

```
A    myapp.example.com    <VPS IP>
```

---

## 10. Rollback

### Sovereign

```bash
# Push a previous tag to trigger CI deploy:
git tag v0.9.9 && git push origin v0.9.9

# Or directly on VPS (no CI needed):
ssh deploy@<VPS IP>
cd /opt/apps/sovereign
SOVEREIGN_VERSION=v0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose pull
SOVEREIGN_VERSION=v0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose up -d
```

Data lives in `sovereign_pgdata` (Postgres) and `sovereign_data` (uploads/plugins) named
Docker volumes. Neither is touched by an image swap.

### Caddy config

Revert the commit in your infra repo and push to `main`. CI applies it automatically.

---

## 11. Backups

### What gets backed up

| Component           | Contents                    | Method                         |
| ------------------- | --------------------------- | ------------------------------ |
| Postgres database   | Platform + auth data        | `pg_dump` → gzip → age encrypt |
| User avatars        | Profile images              | tar → age encrypt              |
| Plugin manifest     | `sovereign.plugins.json`    | copy → age encrypt             |
| Isolated plugin DBs | `plugins/*.db` SQLite files | tar → age encrypt              |

All four are age-encrypted before leaving the VPS and pushed to your private backup repo
as a dated commit. Runs daily at 03:00 UTC, retained 30 days. Components with no data
yet are skipped cleanly.

**Note:** restoring Postgres alone is not sufficient — isolated plugin databases live in
the `sovereign_data` volume, not in Postgres. Restore all four components for a complete
recovery.

### One-time setup

**1. Create the backup repo on GitHub**

Create a private repo (e.g. `<your-org>/sovereign-backups`). Leave it empty — the
first successful backup initializes the `main` branch.

**2. Create a GitHub PAT for backup writes**

GitHub → Settings → Developer settings → Fine-grained tokens:

- Resource owner: `<your-org>`
- Repository: `sovereign-backups` only
- Permissions: Contents → Read and write

**3. Add backup config to your `.env`**

```bash
nano apps/sovereign/.env
# Set:
#   BACKUP_GITHUB_TOKEN=<token>
#   BACKUP_GITHUB_REPO=<your-org>/sovereign-backups
#   AGE_PUBLIC_KEY=age1...  (from step 3 above)

./scripts/encrypt-env.sh sovereign
git add apps/sovereign/.env.enc && git commit -m "secrets: add backup credentials"
git push origin main
```

**4. Install the backup cron on the VPS**

Backups are **not** enabled automatically by `bootstrap/setup.sh`. Bootstrap only
creates `/opt/backups-repo` with the right ownership. Install the cron after
`apps/sovereign/.env.enc` has been pushed and CI has decrypted it to
`/opt/apps/sovereign/.env`, because the installer needs `BACKUP_GITHUB_TOKEN`,
`BACKUP_GITHUB_REPO`, and `AGE_PUBLIC_KEY`.

```bash
ssh deploy@<VPS IP>
cd /opt/infra
./scripts/install-backup-cron.sh
```

`bootstrap/setup.sh` creates `/opt/backups-repo` and gives it to the `deploy` user.
On older servers provisioned before that directory existed, create or fix it once as
root:

```bash
sudo install -d -o deploy -g deploy /opt/backups-repo
# or, if it already exists:
sudo chown -R deploy:deploy /opt/backups-repo
```

The cron job runs the script directly from `/opt/infra/scripts/backup-sovereign.sh` —
script updates take effect after the next `git pull` (automatic on every infra push).
The cron entry sets `PATH=/usr/local/bin:/usr/bin:/bin` so tools installed under
`/usr/local/bin` such as `age` are available in the non-interactive cron environment.

**5. Test it**

```bash
/opt/infra/scripts/backup-sovereign.sh
# Logs: ~/logs/sovereign-backup.log
```

The first run works against a truly empty backup repo: the script creates the initial
backup commit and pushes it to `main`. Later runs fetch and reset to `origin/main`
before adding the next dated backup so the local clone stays aligned with the remote.

### Restore

```bash
ssh deploy@<VPS IP>

# See available backups:
ls /opt/backups-repo/sovereign/

# Restore (interactive — shows a plan and asks for confirmation):
cd /opt/infra
./scripts/restore-sovereign.sh 20260627-030000
```

---

## 12. Secrets Management

```
password manager
  └── ~/.age/key.txt  ← the one secret you protect manually

git (this repo)
  ├── env.example.yml              ← template, committed, no secrets
  ├── env.yml                      ← YOUR real values, git ignored, never committed
  ├── apps/sovereign/.env.example  ← deployment skeleton, committed, auto-synced from upstream
  └── apps/sovereign/.env.enc      ← age-encrypted, safe to commit

VPS
  └── /opt/apps/sovereign/.env     ← decrypted at deploy time, never in git
```

Operators edit **`env.yml`**, never `apps/sovereign/.env` directly — the latter is
generated output and gets overwritten on every run. `scripts/generate-env.js` is the
single tool for all three of the workflows below: it fetches the latest upstream
`apps/sovereign/.env.example`, renders `apps/sovereign/.env` from `env.yml`, validates
that nothing required is missing or still a placeholder, and encrypts the result to
`apps/sovereign/.env.enc` (via `scripts/encrypt-env.sh`).

```
node scripts/generate-env.js sovereign                  # fetch + render + encrypt
node scripts/generate-env.js sovereign --env-file env.yml  # explicit env.yml path (default)
node scripts/generate-env.js sovereign --check           # validate only, write nothing
node scripts/generate-env.js sovereign --no-fetch         # skip the network fetch
```

If a required value is missing or a placeholder (`YOUR_RUNTIME_DOMAIN`, `changeme`, etc.)
survives into the render, the command fails with the list of offending variable **names**
— never values — and writes nothing.

### First-time setup

```bash
npm install                    # once, installs js-yaml (scripts/generate-env.js)
cp env.example.yml env.yml     # git ignored — never commit this copy
nano env.yml                   # fill in all required values
node scripts/generate-env.js sovereign
git add apps/sovereign/.env.example apps/sovereign/.env.enc
git commit -m "secrets: update sovereign"
git push origin main
# CI decrypts and installs on VPS automatically
```

### Rotate a secret

```bash
nano env.yml   # edit the one value you're rotating
node scripts/generate-env.js sovereign
git add apps/sovereign/.env.enc && git commit -m "secrets: rotate AUTH_SECRET"
git push origin main
# Apply immediately without a full deploy:
ssh deploy@<VPS IP> "cd /opt/apps/sovereign && docker compose up -d"
```

### Sync .env.example with upstream sovereign

Every normal (non-`--check`, non-`--no-fetch`) run fetches the latest upstream
`.env.example` and rewrites `apps/sovereign/.env.example` if it changed, preserving
everything below the `# ══ deployment overrides` line untouched:

```bash
node scripts/generate-env.js sovereign
git diff apps/sovereign/.env.example
git add apps/sovereign/.env.example apps/sovereign/.env.enc
git commit -m "chore: sync sovereign .env.example"
```

`--check` never writes any file, including `.env.example` — use it only to validate
`env.yml` (e.g. in CI) without touching the working tree.

---

## 13. Reference

### Port registry

See `docs/ports.md`.

| Port | App               |
| ---- | ----------------- |
| 4000 | sovereign-runtime |
| 4001 | sovereign-auth    |
| 5000 | (next app)        |

### Key Sovereign environment variables

| Variable                     | Notes                                                                        |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `NEXT_PUBLIC_RUNTIME_URL`    | Public runtime URL (e.g. `https://example.com`)                              |
| `AUTH_BASE_URL`              | Public auth URL (e.g. `https://auth.example.com`)                            |
| `AUTH_COOKIE_DOMAIN`         | Cookie shared across subdomains (e.g. `.example.com`)                        |
| `AUTH_WEBAUTHN_RP_ID`        | Bare registrable domain (e.g. `example.com`) — changing invalidates passkeys |
| `AUTH_WEBAUTHN_ORIGIN`       | Comma-separated origins for passkeys                                         |
| `RUNTIME_PORT` / `AUTH_PORT` | Host ports (defaults: 4000 / 4001)                                           |
| `POSTGRES_PASSWORD`          | Generate: `openssl rand -base64 32`                                          |
| `COMPOSE_FILE`               | `docker-compose.prod.yml:docker-compose.postgres.yml`                        |
| `BACKUP_GITHUB_REPO`         | Backup destination (e.g. `myorg/sovereign-backups`)                          |
| `AGE_PUBLIC_KEY`             | `age1...` — your age public key                                              |

### Key file locations on VPS

| Path                                              | What it is                                  |
| ------------------------------------------------- | ------------------------------------------- |
| `/opt/infra/`                                     | git clone of this repo                      |
| `/opt/infra/caddy/`                               | Caddy config (synced on every push to main) |
| `/opt/apps/sovereign/docker-compose.prod.yml`     | Fetched from sovereign release              |
| `/opt/apps/sovereign/docker-compose.postgres.yml` | Fetched from sovereign release              |
| `/opt/apps/sovereign/docker-compose.override.yml` | Copied from infra repo (if present)         |
| `/opt/apps/<name>/.env`                           | App secrets — NOT in git                    |
| `/opt/apps/<name>/.deploy-version`                | Currently deployed tag                      |
| `/opt/backups-repo/`                              | Clone of your backup repo                   |
| `~/logs/`                                         | Backup and app logs                         |

---

## 14. Troubleshooting

### CI sync fails: `mkdir: cannot create directory '/opt/apps': Permission denied`

The `deploy` user doesn't have write access to `/opt/apps` — either it doesn't exist yet
or it's owned by root. Fix as root on the VPS:

```bash
mkdir -p /opt/apps
chown -R deploy:deploy /opt/apps
```

Then re-trigger CI:

```bash
git tag sync-retry && git push origin sync-retry
```

### CI sync fails: `git pull` error about dubious ownership in `/opt/infra`

Git refuses to operate on a repo owned by a different user. Run as root:

```bash
git config --global --add safe.directory /opt/infra
```

This happens because the repo was cloned as root but CI pulls as `deploy`. The permanent
fix is to re-run bootstrap (which transfers the repo to `deploy` via `chown`).

### Site returns 502 but Caddy is running

Caddy is up but the sovereign containers aren't. Push a version tag to trigger the deploy
job:

```bash
git tag v0.9.10 && git push origin v0.9.10
```

If the tag already exists (e.g. from a previous failed attempt), delete and re-push:

```bash
git tag -d v0.9.10
git push origin :refs/tags/v0.9.10
git tag v0.9.10 && git push origin v0.9.10
```

Note: the `v*` tag triggers the deploy when pushed to **this repo**, not `sovereignfs/sovereign`.
The sovereign repo tag triggers image builds; this repo's tag triggers the deploy.

### SSH hardening step fails: `Unit sshd.service not found`

Ubuntu 24.04 uses `ssh.service`. The bootstrap script handles this automatically.
If you see this on an older script version:

```bash
systemctl restart ssh
```

### Page shows 404 on first load after a deploy but works on refresh

The PWA service worker keeps the previous build's HTML in its cache. A hard refresh
(`Cmd ⇧ R` / `Ctrl Shift R`) bypasses the cache. From Sovereign v0.9.9+, the service
worker activates immediately on install — the window is narrower but can still occur.

### Useful commands

```bash
# Check what's running
docker ps

# Logs
/opt/infra/scripts/logs.sh              # sovereign-runtime, follow
/opt/infra/scripts/logs.sh auth         # sovereign-auth
/opt/infra/scripts/logs.sh postgres     # sovereign-postgres
/opt/infra/scripts/logs.sh caddy        # caddy
/opt/infra/scripts/logs.sh runtime --tail 50 --no-follow

# Validate and reload Caddy
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile

# Admin health check
curl -s -H "Authorization: Bearer $SOVEREIGN_ADMIN_KEY" \
  https://example.com/api/admin/health | jq .

# Check deployed version
cat /opt/apps/sovereign/.deploy-version

# Prune old Docker images
docker image prune -f
```
