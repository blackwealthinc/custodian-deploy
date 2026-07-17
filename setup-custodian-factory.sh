#!/bin/bash
# ============================================================================
# Custodian Factory Setup - Single-Client Demo
# ============================================================================
#
# What this does:
#   Turns a bare Ubuntu 22.04/24.04 LTS server into a running Custodian
#   environment with Hermes Agent (backend) + Open WebUI (frontend).
#
# What it installs:
#   1. Docker Engine (from official Docker apt repository)
#   2. Hermes Agent image (nousresearch/hermes-agent:latest)
#   3. Open WebUI image (ghcr.io/open-webui/open-webui:main)
#
# Ports it opens:
#   8642 - Hermes Agent API (OpenAI-compatible)
#   3000 - Open WebUI chat interface (browser)
#
# Prerequisites:
#   - Ubuntu 22.04 LTS or 24.04 LTS (bare install)
#   - Root access
#   - Internet access
#   - 6GB+ RAM, 4+ CPU cores, 40GB+ disk
#
# How to run:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | bash
#
# Architecture sources:
#   - Docker install: https://docs.docker.com/engine/install/ubuntu/
#   - Hermes Docker: https://hermes-agent.nousresearch.com/docs/user-guide/docker
#   - Open WebUI: https://docs.openwebui.com/getting-started/quick-start/
#   - Architecture: features/hermes-openwebui-docker-architecture.md
#   - Timezone: features/timezone-ntp-configuration.md
#   - Professional reference: library/professional-engineering/docker-professional-reference.md
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release | tr -d '"')
OS_VER=$(grep -oP 'VERSION_ID="?\K[0-9.]+' /etc/os-release)
COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

echo -e "${GREEN}"
echo "  Custodian Factory - Single-Client Demo Setup"
echo "  OS: $OS_ID $OS_VER | Host: $(hostname) | $(date)"
echo -e "${NC}"

# ============================================================
# STEP 0: Timezone & NTP
# Source: features/timezone-ntp-configuration.md
# Docker inherits host kernel clock. Set host time first.
# Ubuntu 22.04+ uses systemd-timesyncd (built-in, no install).
# ============================================================
log_step "Step 0: Timezone & NTP"
timedatectl set-timezone America/Chicago
systemctl enable --now systemd-timesyncd 2>/dev/null || true
timedatectl | grep -E "Time zone|NTP service|synchronized"
log_ok "Timezone: $(timedatectl show -p Timezone --value)"

# ============================================================
# STEP 1: System Update
# ============================================================
log_step "Step 1: System Update"
export DEBIAN_FRONTEND=noninteractive
apt update -qq && apt upgrade -y -qq
log_ok "System updated"

# ============================================================
# STEP 2: Firewall Off (demo/testing CT on internal LAN)
# ============================================================
log_step "Step 2: Firewall"
ufw disable 2>/dev/null || true
iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F
log_ok "All ports open (internal LAN demo)"

# ============================================================
# STEP 3: Docker Installation
# Source: https://docs.docker.com/engine/install/ubuntu/
# Exact commands from official docs. No guessing.
# Works on Ubuntu 22.04 AND 24.04 (same repo structure).
# ============================================================
log_step "Step 3: Docker Installation"
read -p "  Install Docker Engine? (y/n): " -n 1 -r DO_DOCKER
echo
if [[ ! $DO_DOCKER =~ ^[Yy]$ ]]; then
    log_warn "Docker SKIPPED. Run 'curl -fsSL https://get.docker.com | sh' later."
    exit 0
fi

# Remove old packages (safe on fresh install)
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y $pkg 2>/dev/null || true
done

# Prerequisites
apt-get install -y -qq ca-certificates curl

# Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Docker apt repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

# Install Docker Engine + Compose plugin
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker
systemctl enable --now docker
log_ok "Docker: $(docker --version)"
log_ok "Compose: $(docker compose version 2>/dev/null || echo 'OK')"

# ============================================================
# STEP 4: Pull Hermes Agent Image
# Source: https://hermes-agent.nousresearch.com/docs/user-guide/docker
# ============================================================
log_step "Step 4: Hermes Agent Image"
read -p "  Pull Hermes Agent image? (y/n): " -n 1 -r DO_HERMES
echo
if [[ ! $DO_HERMES =~ ^[Yy]$ ]]; then
    log_warn "Hermes pull SKIPPED"
else
    docker pull nousresearch/hermes-agent:latest
    log_ok "Hermes image pulled"
fi

# ============================================================
# STEP 5: Open WebUI + Docker Compose Setup
# Source: features/hermes-openwebui-docker-architecture.md
# ============================================================
log_step "Step 5: Open WebUI + Compose Setup"
read -p "  Set up Open WebUI with docker-compose? (y/n): " -n 1 -r DO_OWUI
echo
if [[ ! $DO_OWUI =~ ^[Yy]$ ]]; then
    log_warn "Open WebUI SKIPPED"
    exit 0
fi

# Generate secure random keys (NEVER hardcoded)
API_SERVER_KEY=$(openssl rand -hex 32)
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
log_info "Generated API_SERVER_KEY: ${API_SERVER_KEY:0:16}..."
log_info "Generated WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY:0:16}..."

# Create data directories
mkdir -p ./hermes-data ./webui-data

# Download compose file if not present
if [ ! -f "docker-compose.custodian-factory.yml" ]; then
    curl -sS -o docker-compose.custodian-factory.yml "$COMPOSE_URL"
    log_ok "Compose file downloaded"
fi

# Deploy
API_SERVER_KEY="$API_SERVER_KEY" WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" docker compose -f docker-compose.custodian-factory.yml up -d

# Save keys
cat > .env.custodian-factory << KEYEOF
# Generated by setup-custodian-factory.sh on $(date)
API_SERVER_KEY=$API_SERVER_KEY
WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY
KEYEOF
chmod 600 .env.custodian-factory
log_ok "Keys saved to .env.custodian-factory"

# ============================================================
# STEP 6: Verification
# ============================================================
log_step "Step 6: Verification"
echo "  Waiting for containers to start (30s)..."
sleep 15

docker compose -f docker-compose.custodian-factory.yml ps

HERMES_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8642/v1/health 2>/dev/null || echo "000")
if [ "$HERMES_CODE" = "200" ]; then
    log_ok "Hermes Agent: healthy (HTTP 200)"
else
    log_warn "Hermes Agent: HTTP $HERMES_CODE (may still be starting)"
fi

OWUI_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null || echo "000")
if [ "$OWUI_CODE" = "200" ] || [ "$OWUI_CODE" = "302" ]; then
    log_ok "Open WebUI: reachable (HTTP $OWUI_CODE)"
else
    log_warn "Open WebUI: HTTP $OWUI_CODE (may still be starting)"
fi

# ============================================================
# SUMMARY
# ============================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  CUSTODIAN FACTORY - SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  Open WebUI:  http://${SERVER_IP}:3000"
echo "  Hermes API:  http://localhost:8642/v1"
echo ""
echo "  One-liner verification:"
echo "    curl -s http://localhost:8642/v1/health && echo && curl -s -o /dev/null -w '%{http_code}' http://localhost:3000"
echo ""
echo "  To stop:"
echo "    docker compose -f docker-compose.custodian-factory.yml down"
echo ""
