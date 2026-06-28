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
SOVEREIGN_VERSION=0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose pull
SOVEREIGN_VERSION=0.9.9 COMPOSE_FILE=docker-compose.prod.yml:docker-compose.postgres.yml \
  docker compose up -d
```

Data lives in named Docker volumes and is never touched by an image swap.

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

| Service | Missing vars | Impact |
|---|---|---|
| `auth` | `AUTH_WEBAUTHN_RP_ID`, `AUTH_WEBAUTHN_RP_NAME`, `AUTH_WEBAUTHN_ORIGIN` | RP_ID defaults to the auth subdomain hostname — passkeys registered on the runtime origin cannot be verified. Must be the bare registrable domain (e.g. `example.com`) to work across subdomains. |
| `runtime` | `LOG_LEVEL` | Log level always defaults to `warn`; `debug`/`info` are unreachable via `.env`. |
| `runtime` | `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_CONTACT` | Push notifications silently disabled even when configured. |
| `runtime` | `NOTIFICATION_TRANSPORT`, `REDIS_URL` | SSE/Redis transport unreachable without explicit compose configuration. |

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
