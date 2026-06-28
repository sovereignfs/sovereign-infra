#!/usr/bin/env bash
# bootstrap/setup.sh
# One-time setup for a fresh Ubuntu 24.04 VPS.
# Run as root after cloning this repo onto the VPS.
#
# Prerequisites:
#   # TODO: Replace YOUR_ORG/YOUR_INFRA_REPO with your forked/cloned repo path.
#   # Clone the infra repo to the VPS first:
#   git clone https://x-access-token:<YOUR_INFRA_REPO_TOKEN>@github.com/YOUR_ORG/YOUR_INFRA_REPO.git /opt/infra
#
#   # Then SSH in and run:
#   ssh root@<VPS IP>
#   bash /opt/infra/bootstrap/setup.sh

set -euo pipefail

INFRA_DIR="/opt/infra"
VPS_USER="deploy"

if [[ ! -d "$INFRA_DIR/.git" ]]; then
  echo "Error: $INFRA_DIR is not a git repo." >&2
  echo "Clone it first:" >&2
  echo "  git clone https://x-access-token:<YOUR_INFRA_REPO_TOKEN>@github.com/YOUR_ORG/YOUR_INFRA_REPO.git $INFRA_DIR" >&2
  exit 1
fi

echo "==> Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq

echo "==> Installing dependencies"
apt-get install -y -qq ca-certificates curl git jq ufw

echo "==> Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "==> Configuring Docker log rotation"
# Cap each container at 20 MB × 5 files — prevents logs from filling the disk.
# Applies to all containers; no compose-level changes needed.
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
EOF
systemctl restart docker

echo "==> Creating deploy user"
if ! id "$VPS_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$VPS_USER"
fi
usermod -aG docker "$VPS_USER"

# Generate a strong random password for emergency VPS web-console access.
# SSH password authentication is disabled below — this password is only usable
# via your VPS provider's web console (a last-resort recovery path).
DEPLOY_PASS=$(openssl rand -base64 24 | tr -d '/+=')
echo "$VPS_USER:$DEPLOY_PASS" | chpasswd

echo "==> Setting up deploy user SSH (paste CI public key, then Ctrl+D):"
mkdir -p /home/$VPS_USER/.ssh
cat >> /home/$VPS_USER/.ssh/authorized_keys
chmod 700 /home/$VPS_USER/.ssh
chmod 600 /home/$VPS_USER/.ssh/authorized_keys
chown -R $VPS_USER:$VPS_USER /home/$VPS_USER/.ssh

echo "==> Setting up log directory for deploy user"
mkdir -p /home/$VPS_USER/logs
chown -R $VPS_USER:$VPS_USER /home/$VPS_USER/logs

echo "==> Configuring logrotate for app logs"
cat > /etc/logrotate.d/sovereign-infra <<'EOF'
/home/deploy/logs/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  create 0640 deploy deploy
}
EOF

echo "==> Hardening SSH (disable password auth, ensure key auth)"
# Password auth is disabled — the deploy password above is for VPS console only.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo "==> Configuring firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP (Caddy ACME + redirect)'
ufw allow 443/tcp  comment 'HTTPS'
ufw --force enable

echo "==> Setting ownership of infra repo"
# Repo was cloned as root — hand it to deploy so CI git pulls work
chown -R $VPS_USER:$VPS_USER "$INFRA_DIR"

# Verify the remote URL has a token embedded (set at clone time).
# To rotate: sudo -u deploy git -C /opt/infra remote set-url origin \
#              https://x-access-token:<NEW_TOKEN>@github.com/YOUR_ORG/YOUR_INFRA_REPO.git
CURRENT_REMOTE=$(git -C "$INFRA_DIR" remote get-url origin)
if [[ "$CURRENT_REMOTE" != *"x-access-token"* ]]; then
  echo "Warning: remote URL has no embedded token — CI git pulls may require auth."
  echo "  Update with:"
  echo "  sudo -u deploy git -C $INFRA_DIR remote set-url origin https://x-access-token:<TOKEN>@github.com/YOUR_ORG/YOUR_INFRA_REPO.git"
fi

echo "==> Creating app directories"
mkdir -p /opt/apps
chown -R $VPS_USER:$VPS_USER /opt/apps

echo "==> Symlinking app compose files from infra repo"
# Only symlink apps that have a docker-compose.yml in the infra repo.
# Apps managed by their own CI (like sovereign) don't have one — skip them.
linked=0
for app_dir in "$INFRA_DIR"/apps/*/; do
  app_name=$(basename "$app_dir")
  [[ "$app_name" == "_template" ]] && continue
  compose_src="$INFRA_DIR/apps/$app_name/docker-compose.yml"
  [[ -f "$compose_src" ]] || continue
  mkdir -p "/opt/apps/$app_name"
  ln -sf "$compose_src" "/opt/apps/$app_name/docker-compose.yml"
  chown -h $VPS_USER:$VPS_USER "/opt/apps/$app_name/docker-compose.yml"
  echo "  Linked /opt/apps/$app_name/docker-compose.yml"
  linked=$((linked + 1))
done
[[ $linked -eq 0 ]] && echo "  (no infra-managed compose files to link)"

# Ensure the sovereign app directory exists even though its compose is managed
# by the sovereign deploy workflow, not a symlink from this repo.
mkdir -p /opt/apps/sovereign
chown -R $VPS_USER:$VPS_USER /opt/apps/sovereign

VPS_IP=$(curl -s ifconfig.me)

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Bootstrap complete."
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Deploy user credentials"
echo "  ─────────────────────────────────────────────────────────"
echo "  Username: $VPS_USER"
echo "  Password: $DEPLOY_PASS"
echo ""
echo "  This password is for emergency VPS web-console access ONLY."
echo "  SSH password authentication is DISABLED — normal SSH access"
echo "  requires the key you just pasted."
echo ""
echo "  !! Save this password in your password manager now. !!"
echo "  !! It will not be shown again.                      !!"
echo "  ─────────────────────────────────────────────────────────"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Add GitHub Actions secrets to your infra repo:"
echo "     VPS_HOST        = $VPS_IP"
echo "     VPS_USER        = $VPS_USER"
echo "     VPS_SSH_KEY     = <contents of ~/.ssh/sovereign_ci_deploy>"
echo "     AGE_PRIVATE_KEY = <contents of ~/.age/key.txt>"
echo ""
echo "  2. Set up sovereign's .env:"
echo "     Locally:"
echo "       cp apps/sovereign/.env.example apps/sovereign/.env"
echo "       nano apps/sovereign/.env   # fill in all required values"
echo "       ./scripts/encrypt-env.sh sovereign"
echo "       git add apps/sovereign/.env.enc"
echo "       git commit -m 'secrets: sovereign initial'"
echo "       git push origin main"
echo "     CI decrypts and installs it on the VPS automatically."
echo ""
echo "  3. Start Caddy:"
echo "     ssh deploy@$VPS_IP"
echo "     cd /opt/infra/caddy && docker compose up -d"
echo ""
echo "  4. First sovereign deploy:"
echo "     git tag v0.9.10 && git push origin v0.9.10"
echo "     CI verifies the images and deploys automatically."
echo ""
echo "  See README.md for the full walkthrough."
