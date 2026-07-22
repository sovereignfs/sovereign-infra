# Sovereign Self-Hosting: Deploy Workflow

This document explains the two-repo model used to host a Sovereign instance on a
self-managed VPS. This repo is a ready-to-use template — fork it (or use it as a
GitHub template) to host your own instance.

---

## Architecture overview

```
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│   sovereignfs/sovereign         │    │   <you>/sovereign-infra         │
│                                 │    │                                 │
│   Source of truth for:          │    │   Source of truth for:          │
│   • Application code            │    │   • Caddy reverse proxy config  │
│   • Dockerfiles                 │    │   • Per-app docker-compose      │
│   • docker-compose.prod.yml     │    │   • Encrypted .env files        │
│   • docker-compose.postgres.yml │    │   • Bootstrap + scripts         │
│                                 │    │                                 │
│   Trigger: push v* tag          │    │   Trigger: push v* tag (same    │
│   → build + push images to GHCR │    │     version) → deploy to VPS   │
└─────────────────────────────────┘    └─────────────────────────────────┘
               │  images on GHCR                      │  SSH → VPS
               └─────────────────────────┬────────────┘
                                         ▼
                                    Your VPS
                                  (Caddy + Docker)
```

**Role split:**
- `sovereignfs/sovereign` is the **provider** — it builds and publishes Docker images when a version tag is pushed. It has no knowledge of where you run it.
- Your infra repo is the **operator** — it controls when and where those images go. Push the same version tag to your infra repo to trigger a deploy.

This means:
- Sovereign upgrades don't happen without your explicit action (push a matching tag)
- Your deployment config, secrets, and Caddy setup are entirely under your control
- You can pin to any version and roll back instantly

---

## What you need

### 1. Docker images for sovereign

The official `sovereignfs/sovereign` images are published to GHCR on every release.
If you are running the official release, no action is needed — the deploy workflow
pulls from `ghcr.io/sovereignfs/sovereign-{runtime,auth}:<version>` automatically.

If you are running a **fork** of sovereign, add a publish workflow to your fork at
`.github/workflows/publish.yml`:

```yaml
name: Publish Docker images

on:
  push:
    tags:
      - 'v*'

jobs:
  publish:
    name: Build and push ${{ github.ref_name }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push sovereign-runtime
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/sovereign-runtime:${{ github.ref_name }}
            ghcr.io/${{ github.repository_owner }}/sovereign-runtime:latest

      - name: Build and push sovereign-auth
        uses: docker/build-push-action@v5
        with:
          context: .
          file: apps/auth/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/sovereign-auth:${{ github.ref_name }}
            ghcr.io/${{ github.repository_owner }}/sovereign-auth:latest
```

Then update the image references in `.github/workflows/sync.yml` to match your registry.

### 2. Deploy workflow in your infra repo

Already present at `.github/workflows/sync.yml` as the `deploy` job.
It runs only on `v*` tags and has `needs: sync` — this guarantees secrets are installed
before `docker compose` runs.

### 3. GitHub secrets

Add these to your infra repo (Settings → Secrets → Actions):

| Secret | Value |
|---|---|
| `VPS_HOST` | VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of `~/.ssh/sovereign_ci_deploy` (private key) |
| `AGE_PRIVATE_KEY` | Contents of `~/.age/key.txt` (age private key) |

---

## Deploy flow step by step

### Initial setup (once)

1. Provision the VPS: `bash /opt/infra/bootstrap/setup.sh`
2. Start Caddy: `cd /opt/infra/caddy && docker compose up -d`
3. Create sovereign `.env`:
   ```bash
   cp apps/sovereign/.env.example apps/sovereign/.env
   nano apps/sovereign/.env          # fill in all required values
   ./scripts/encrypt-env.sh sovereign
   git add apps/sovereign/.env.enc
   git commit -m "secrets: sovereign initial"
   git push origin main              # CI installs .env on VPS
   ```

### Deploy a new version

1. Check that the sovereign release has been published on GHCR:
   ```bash
   docker manifest inspect ghcr.io/sovereignfs/sovereign-runtime:v0.9.10
   ```

2. Push a matching tag to your infra repo:
   ```bash
   git tag v0.9.10
   git push origin v0.9.10
   ```

The deploy workflow:
- Verifies images exist (fails fast if the release isn't published yet)
- SSHes into VPS; VPS fetches compose files directly from `sovereignfs/sovereign@v0.9.10`
- Copies `docker-compose.override.yml` to the app directory if present in the infra repo
- Pulls images and restarts containers (healthcheck chain: postgres → auth → runtime)
- Prunes old images
- Records the deployed version in `.deploy-version`

### Rollback

```bash
git tag v0.9.9 -f   # re-tag (or use any previous tag)
git push origin v0.9.9
```

Or directly on the VPS:
```bash
ssh deploy@<VPS IP>
cd /opt/apps/sovereign
SOVEREIGN_VERSION=v0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose pull
SOVEREIGN_VERSION=v0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose up -d
```

Data lives in named Docker volumes and is never touched by an image swap.

---

## Rebuilding after a `sovereign.plugins.json`-only change

If `sovereign.plugins.json` exists at this repo's root, every `v*` deploy
already builds a custom `sovereign-runtime` image with those plugins baked
in (see the `deploy-custom` job in `.github/workflows/sync.yml`). But
editing `sovereign.plugins.json` alone — adding a plugin, bumping a
plugin's `ref`, pointing at a different `repository` — does **not** by
itself trigger a rebuild. The workflow only builds when it runs against a
`v*` version, so a plugins-only edit just sits committed and inert until
the next real version bump.

Two ways to pick it up without bumping the sovereign version:

**1. Re-point the existing version tag and re-push it:**

```bash
git tag v0.9.10 -f
git push origin v0.9.10 -f
```

This re-fires the tag-push event, so `deploy-custom` reruns and rebuilds
the image from the current `sovereign.plugins.json`, still pinned to the
same sovereign source version. No workflow changes needed — this works
today.

**2. Run the workflow manually from the Actions tab:**

Go to `.github/workflows/sync.yml` in the Actions tab → "Run workflow", and
supply the `sovereign_version` input (e.g. `v0.9.10`). This runs the exact
same `sync` → `deploy-custom` path as a tag push, without moving any git
tag. Prefer this if you don't want force-pushed tags in your history.

Either way, the version you supply must already be published on GHCR
(`sovereign-auth` at minimum — `sovereign-runtime` is rebuilt locally in
the custom-image path, so it doesn't need to exist there).

**Env-var-only changes need neither of these.** They're never baked into
the image — they're read from `.env` at container start — so the existing
"push any non-`v*` tag" restart pass below already picks them up,
including for an app running a custom image.

---

## Rotating secrets / applying an `.env` change

### Recommended: push a tag, let CI handle it

```bash
./scripts/encrypt-env.sh sovereign
git add apps/sovereign/.env.enc
git commit -m "secrets: rotate <whatever changed>"
git push origin main

git tag env-update      # any non-v* tag name works
git push origin env-update
```

The `sync` job decrypts, installs the new `.env` on the VPS, reloads Caddy,
**and now also restarts every already-deployed app** so the change actually
takes effect — it used to stop after installing the file, silently leaving
the rotation inert until the next full version deploy. It only skips this
restart for `v*` tags, since the `deploy` job that follows restarts sovereign
again anyway with the new version.

### Applying an env change manually (without pushing a tag)

The deploy user (`deploy`) has **no `sudo` access**, by design — the VPS is
provisioned that way for a reason, don't add it. `age` is preinstalled
system-wide by `bootstrap/setup.sh`, so decrypting on the VPS doesn't need
sudo either. What it does need is the age **private** key, which is **not**
on the VPS by default — it only lives in your local machine / password
manager and in the `AGE_PRIVATE_KEY` GitHub secret.

Putting that key on the VPS permanently is a real security tradeoff: anyone
who later compromises this VPS (or any other app running on it) can then
decrypt every app's `.env.enc`, not just sovereign's. Prefer the tag-push
path above unless you have a specific reason to do this by hand.

If you do need to do it manually:

1. **Pull the latest infra repo** on the VPS (to get a `.env.enc` you just
   committed):
   ```bash
   ssh deploy@<VPS_HOST>
   cd /opt/infra && git pull origin main
   ```

2. **Get the age private key onto the VPS** — from your *local* machine, not
   the VPS. `scp` won't create the destination directory for you, so make it
   first:
   ```bash
   ssh deploy@<VPS_HOST> 'mkdir -p ~/.age && chmod 700 ~/.age'
   scp ~/.age/key.txt deploy@<VPS_HOST>:~/.age/key.txt
   ssh deploy@<VPS_HOST> 'chmod 600 ~/.age/key.txt'
   ```

3. **Decrypt** (back on the VPS):
   ```bash
   cd /opt/infra
   ./scripts/decrypt-env.sh sovereign ~/.age/key.txt
   ```

4. **Restart the containers** — this is the step that's easy to miss.
   Sovereign's compose files aren't stored in this repo; they're fetched
   fresh from the tagged `sovereignfs/sovereign` release only during a real
   deploy. Don't run a bare `docker compose up -d` in `/opt/apps/sovereign`
   without them present — if the compose files are missing or stale, Compose
   can fall back to trying to *build* images from a local Dockerfile context
   that doesn't exist on this VPS, instead of pulling the published ones
   (`resolve : lstat /opt/apps/sovereign/apps: no such file or directory` is
   this failure mode). Re-fetch the files for whatever version is currently
   running, then restart — include the compose override if you've enabled
   one (see "Known sovereign compose gaps" below):
   ```bash
   cd /opt/apps/sovereign
   VERSION=$(cat .deploy-version)
   BASE="https://raw.githubusercontent.com/sovereignfs/sovereign/${VERSION}"
   curl -fsSL "${BASE}/docker-compose.prod.yml"     -o docker-compose.prod.yml
   curl -fsSL "${BASE}/docker-compose.postgres.yml" -o docker-compose.postgres.yml

   COMPOSE_FILE="docker-compose.prod.yml:docker-compose.postgres.yml"
   [[ -f docker-compose.override.yml ]] && COMPOSE_FILE="${COMPOSE_FILE}:docker-compose.override.yml"

   SOVEREIGN_VERSION="$VERSION" COMPOSE_FILE="$COMPOSE_FILE" docker compose pull
   SOVEREIGN_VERSION="$VERSION" COMPOSE_FILE="$COMPOSE_FILE" docker compose up -d
   ```

5. **Consider removing the private key from the VPS afterward**, since it
   isn't needed there day-to-day:
   ```bash
   rm ~/.age/key.txt
   ```

---

## Caddy config updates

Changes to Caddy config (new vhost, security headers, etc.) are applied
separately from deploys — push to `main` in your infra repo:

```bash
git add caddy/conf.d/mynewapp.caddy docs/ports.md
git commit -m "feat: add mynewapp vhost"
git push origin main
```

The `sync.yml` workflow validates and reloads Caddy automatically.

---

## Adding a new app

See the README for the full checklist. The short version:

1. Copy `apps/_template/` → `apps/<appname>/`; add a compose file
2. Copy `caddy/conf.d/_template.caddy.example` → `caddy/conf.d/<appname>.caddy`
3. Add a port row to `docs/ports.md`
4. Set up `.env.example`, fill in `.env`, encrypt and commit `.env.enc`
5. Push to `main` (Caddy updates) + push a tag (app deploys)

---

## Known sovereign compose gaps

These env vars are read by the sovereign code but **not in sovereign's `docker-compose.prod.yml`
`environment:` blocks**, so they have no effect even when set in `.env`.

**Fixed as of `v0.19.3`** (no longer gaps — confirmed present in that release's
`docker-compose.prod.yml`): `AUTH_WEBAUTHN_RP_ID`, `AUTH_WEBAUTHN_RP_NAME`,
`AUTH_WEBAUTHN_ORIGIN`, `LOG_LEVEL`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
`VAPID_CONTACT`, `NOTIFICATION_TRANSPORT`, `REDIS_URL`. If you activated the
override for these, it's now redundant (harmless, but safe to trim) on any
deploy at `v0.19.3` or later.

| Service   | Missing var          | Impact                                                                                                                                                                                                                                          |
| --------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `runtime` | `SOVEREIGN_VAULT_KEY` | The plugin secret vault (`sdk.secrets`) fails closed with no default — confirmed still missing from `docker-compose.prod.yml` as of `v0.19.3`. Surfaces as a runtime error the first time a plugin stores/reads a secret, not at container startup. Hit in practice via Plainwrite: "Connect using a token" fails with `SOVEREIGN_VAULT_KEY is required before sdk.secrets can store or read secret values.` A fix is in progress upstream (sovereign PR wiring it into the compose environment block); until a release tag ships with it, this stays an override-file workaround. |

**Fix:** activate the compose override file included in this repo:

```bash
cp apps/sovereign/docker-compose.override.yml.example \
   apps/sovereign/docker-compose.override.yml
git add apps/sovereign/docker-compose.override.yml
git commit -m "config: enable compose override for upstream env var gaps"
git push origin main
```

The CI deploy job detects the override file and automatically includes it in the
compose stack alongside the upstream files. On the next `v*` tag push, all
missing vars will be passed to the containers from `.env`.

Once `sovereignfs/sovereign` adds these vars to its own compose file, the override
can be removed.
