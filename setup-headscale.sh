#!/bin/bash
# ============================================================================
# Custodian — Headscale VPN Coordination Server Setup
# ============================================================================
# What this does:
#   Turns a bare Ubuntu 22.04/24.04 server into a Headscale coordination server
#   using Docker. Headscale is the open-source Tailscale control plane — all your
#   machines connect to it and get private 100.64.0.0/10 IPs on a mesh VPN.
#
# Prerequisites:
#   - Ubuntu 22.04 LTS or 24.04 LTS
#   - Root access
#   - Internet access (port 443 outbound to Docker Hub + GitHub)
#
# Environment variables (all optional):
#   HEADSCALE_PORT     — port to expose (default: 8080)
#   HEADSCALE_VERSION  — Docker image tag (default: latest)
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-headscale.sh | sudo -E bash
#
# Architecture: custodian-home-lab-setup.md § Phase 1
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

# ── Configuration ──
HEADSCALE_PORT="${HEADSCALE_PORT:-8080}"
HEADSCALE_VERSION="${HEADSCALE_VERSION:-latest}"
HEADSCALE_BASE="/opt/headscale"

OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release | tr -d '"')
OS_VER=$(grep -oP 'VERSION_ID="?\K[0-9.]+' /etc/os-release)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}"
echo "  Custodian — Headscale VPN Server Setup"
echo "  OS: $OS_ID $OS_VER | Host: $(hostname) | IP: $SERVER_IP"
echo -e "${NC}"

# ============================================================
# STEP 1: System Update
# ============================================================
log_step "Step 1: System Update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl
log_ok "System updated"

# ============================================================
# STEP 2: Docker Installation (with LXC auto-detection)
# ============================================================
log_step "Step 2: Docker Installation"

IS_LXC=false

# Detection method 1: systemd container type
if [ -f /run/systemd/container ]; then
    CONTAINER_TYPE=$(cat /run/systemd/container 2>/dev/null || echo "")
    if [ "$CONTAINER_TYPE" = "lxc" ] || [ "$CONTAINER_TYPE" = "lxc-libvirt" ]; then
        IS_LXC=true
        log_info "Detected via /run/systemd/container: $CONTAINER_TYPE"
    fi
fi

# Detection method 2: /proc/1/environ contains 'lxc'
if grep -qa 'lxc' /proc/1/environ 2>/dev/null; then
    IS_LXC=true
    log_info "Detected via /proc/1/environ (lxc kernel environment)"
fi

# Detection method 3: lxc directories present
if [ -d /dev/lxd ] || [ -d /var/lib/lxc ]; then
    IS_LXC=true
    log_info "Detected via LXC directory presence (/dev/lxd or /var/lib/lxc)"
fi

if command -v docker &>/dev/null; then
    # Docker already installed — check if it's LXC-compatible
    if [ "$IS_LXC" = true ]; then
        CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
        if dpkg --compare-versions "$CONTAINERD_VER" ge "1.7.28" 2>/dev/null; then
            log_warn "containerd $CONTAINERD_VER on LXC is broken — switching to docker.io..."
            apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            apt-get update -qq
            apt-get install -y -qq docker.io docker-compose-v2
            systemctl restart docker
        else
            log_ok "Docker already installed (containerd $CONTAINERD_VER, LXC-compatible)"
        fi
    else
        log_ok "Docker already installed: $(docker --version)"
    fi
else
    if [ "$IS_LXC" = true ]; then
        # ── Proxmox LXC path: Ubuntu's docker.io package ──
        # docker-ce pulls containerd 1.7.x which triggers
        # "ip_unprivileged_port_start: permission denied" inside LXC.
        # docker.io ships containerd 1.6.x which works in LXC.
        # See: research/proxmox-lxc-containerd-fix-plan.md
        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-v2
    else
        # ── Bare metal / cloud VM path: official Docker repo ──
        log_info "Bare metal / VM — using official Docker Engine (containerd latest)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
fi

log_ok "Docker: $(docker --version)"

# Add custodian user to docker group (non-root Docker access)
if id custodian &>/dev/null; then
    usermod -aG docker custodian 2>/dev/null || true
    log_ok "custodian user added to docker group"
fi

# ============================================================
# STEP 3: Headscale Deployment
# ============================================================
log_step "Step 3: Headscale Deployment"

# Create directories
mkdir -p "$HEADSCALE_BASE/config" "$HEADSCALE_BASE/data"

# Generate minimal config.yaml if it doesn't exist (idempotent)
if [ ! -f "$HEADSCALE_BASE/config/config.yaml" ]; then
    log_info "Generating Headscale config.yaml..."
    cat > "$HEADSCALE_BASE/config/config.yaml" << 'HEADSCALECONF'
---
# Headscale configuration — auto-generated by setup-headscale.sh
# See: https://headscale.net/stable/ref/configuration/

# The URL clients connect to. Set to this server's IP:port.
# Override by setting SERVER_URL env var before running this script.
server_url: http://PLACEHOLDER_SERVER_IP:PLACEHOLDER_PORT

# Listen on all interfaces inside Docker
listen_addr: 0.0.0.0:8080

# Disable metrics listener (not needed for home lab)
metrics_listen_addr: ""

# Trusted proxies (empty — no reverse proxy in front by default)
trusted_proxies: []

# IP allocation for mesh nodes
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

# Noise protocol encryption (Headscale v0.23+)
noise:
  private_key_path: /var/lib/headscale/noise_private.key

# DERP relay — use Tailscale's default DERP map
derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []

# Disable TLS — we use HTTP internally. Add a reverse proxy for HTTPS.
tls_letsencrypt_hostname: ""
tls_letsencrypt_cache_dir: /var/lib/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01

# DNS configuration
dns:
  override_local_dns: true
  magic_dns: true
  base_domain: ns1net.internal
  nameservers:
    global:
      - 9.9.9.9
      - 192.242.2.2

# Database — SQLite (file based, no external DB needed)
database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite

# Log level
log:
  level: info
HEADSCALECONF

    # Replace placeholders with actual values
    sed -i "s/PLACEHOLDER_SERVER_IP/$SERVER_IP/g" "$HEADSCALE_BASE/config/config.yaml"
    sed -i "s/PLACEHOLDER_PORT/$HEADSCALE_PORT/g" "$HEADSCALE_BASE/config/config.yaml"

    log_ok "Config generated at $HEADSCALE_BASE/config/config.yaml"
else
    log_info "Config already exists — skipping generation"
fi

# Pull the Headscale Docker image
log_info "Pulling headscale/headscale:$HEADSCALE_VERSION ..."
docker pull "headscale/headscale:$HEADSCALE_VERSION"
log_ok "Image pulled: headscale/headscale:$HEADSCALE_VERSION"

# Stop and remove existing container if re-running (idempotent)
docker rm -f headscale 2>/dev/null || true

# Run Headscale
log_info "Starting Headscale container..."
docker run -d \
  --name headscale \
  --restart unless-stopped \
  -p "${HEADSCALE_PORT}:8080" \
  -v "$HEADSCALE_BASE/config:/etc/headscale:ro" \
  -v "$HEADSCALE_BASE/data:/var/lib/headscale" \
  "headscale/headscale:$HEADSCALE_VERSION" \
  serve

log_ok "Headscale container started"

# ============================================================
# STEP 4: Health Check
# ============================================================
log_step "Step 4: Health Check"

for i in $(seq 1 20); do
    if curl -sf "http://localhost:${HEADSCALE_PORT}/health" &>/dev/null; then
        log_ok "Headscale healthy (attempt $i)"
        break
    fi
    if [ "$i" -eq 20 ]; then
        log_error "Headscale failed to start after 20 attempts"
        docker logs headscale --tail 50
        exit 1
    fi
    sleep 2
done

# ============================================================
# STEP 5: Create Admin User (idempotent)
# ============================================================
log_step "Step 5: Create Admin User"

# Check if admin user already exists
if docker exec headscale users list 2>/dev/null | grep -q 'admin'; then
    log_ok "Admin user already exists"
else
    log_info "Creating admin user..."
    docker exec headscale users create admin
fi

# ============================================================
# STEP 6: Verify
# ============================================================
log_step "Step 6: Verify"

USERS=$(docker exec headscale users list 2>/dev/null)
log_info "Users:"
echo "$USERS" | while read u; do echo "    $u"; done

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  HEADSCALE VPN SERVER — SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  Server:     http://${SERVER_IP}:${HEADSCALE_PORT}"
echo "  Admin user: admin"
echo "  Config:     ${HEADSCALE_BASE}/config/config.yaml"
echo "  Data:       ${HEADSCALE_BASE}/data/"
echo ""
echo -e "${CYAN}  ── JOIN OTHER MACHINES ──${NC}"
echo ""
echo "  On each client machine, install Tailscale and connect:"
echo ""
echo "    # 1. Install Tailscale client"
echo "    curl -fsSL https://tailscale.com/install.sh | sh"
echo ""
echo "    # 2. Connect to YOUR Headscale server (not Tailscale's)"
echo "    tailscale up --login-server http://${SERVER_IP}:${HEADSCALE_PORT}"
echo ""
echo "    # 3. The browser will open. Go back to terminal and register:"
echo "    docker exec headscale nodes list"
echo "    docker exec headscale nodes register --user admin --key <NODE-KEY>"
echo ""
echo "  After all nodes join, they get IPs in 100.64.0.0/10 range."
echo "  You can SSH between them using those IPs."
echo ""
echo "  ── MANAGEMENT COMMANDS ──"
echo "    docker exec headscale users list"
echo "    docker exec headscale nodes list"
echo "    docker logs -f headscale"
echo "    docker restart headscale"
echo ""
