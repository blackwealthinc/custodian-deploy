#!/bin/bash
# ============================================================================
# Custodian — Kill Bill Billing Engine Setup (Demo)
# ============================================================================
# What this does:
#   Deploys Kill Bill (subscription billing engine) + Kaui (admin UI) +
#   MariaDB on a bare Ubuntu box, via Docker Compose. This is the billing
#   layer for the Custodian AI platform (DEMO/TESTING ONLY — moves to a
#   Contabo VPS later, no production hardening here).
#
#   Three containers:
#     - killbill/killbill:0.24.21  — the billing engine (Java), port 8080
#     - killbill/kaui:4.0.25       — the admin UI, port 9090
#     - killbill/mariadb:0.24      — the database (schema pre-seeded)
#
#   Why MariaDB (not PostgreSQL): Kill Bill's official + simplest path is
#   MariaDB. Its DDL is MySQL-flavoured, and PostgreSQL requires a manual
#   DDL "bridge" + schema load. The MariaDB image ships the schema baked-in,
#   so it works out of the box. (See features/killbill-demo-final-plan.md)
#
# Prerequisites:
#   - Ubuntu 22.04 LTS or 24.04 LTS (bare metal or VM — NOT a Proxmox LXC)
#   - Root access, internet access (Docker Hub + GitHub)
#   - No existing Docker required (this script installs it)
#
# Environment variables (all optional):
#   KILLBILL_VERSION  — engine image tag      (default: 0.24.21)
#   KAUI_VERSION      — admin UI image tag    (default: 4.0.25)
#   MARIADB_VERSION   — database image tag    (default: 0.24)
#   KILLBILL_PORT     — engine port on host   (default: 8080)
#   KAUI_PORT         — admin UI port on host (default: 9090)
#   JAVA_HEAP         — engine JVM heap       (default: -Xmx2g -Xms2g)
#   DB_PASSWORD       — MariaDB root password (default: auto-generated once)
#
# One-liner (run on the target box):
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-killbill.sh | sudo -E bash
#
# Reference: features/killbill-demo-final-plan.md
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
    log_error "Must run as root (use: ... | sudo -E bash)"
    exit 1
fi

# ── Configuration ──
KILLBILL_VERSION="${KILLBILL_VERSION:-0.24.21}"
KAUI_VERSION="${KAUI_VERSION:-4.0.25}"
MARIADB_VERSION="${MARIADB_VERSION:-0.24}"
KILLBILL_PORT="${KILLBILL_PORT:-8080}"
KAUI_PORT="${KAUI_PORT:-9090}"
JAVA_HEAP="${JAVA_HEAP:--Xmx2g -Xms2g}"
KILLBILL_BASE="/opt/killbill"

OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release | tr -d '"')
OS_VER=$(grep -oP 'VERSION_ID="?\K[0-9.]+' /etc/os-release)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}"
echo "  Custodian — Kill Bill Billing Engine Setup (Demo)"
echo "  OS: $OS_ID $OS_VER | Host: $(hostname) | IP: $SERVER_IP"
echo "  Engine: $KILLBILL_VERSION | Kaui: $KAUI_VERSION | MariaDB: $MARIADB_VERSION"
echo -e "${NC}"

# ============================================================
# STEP 1: System Update & Prerequisites
# ============================================================
log_step "Step 1: System Update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl
log_ok "System updated"

# ============================================================
# STEP 2: Docker Installation (LXC auto-detection)
# ============================================================
log_step "Step 2: Docker Installation"

# Auto-detect Proxmox LXC (docker-ce's containerd 1.7.x breaks inside LXC;
# docker.io ships containerd 1.6.x which works). See research/ docs.
IS_LXC=false
if [ -f /run/systemd/container ]; then
    CT_TYPE=$(cat /run/systemd/container 2>/dev/null || echo "")
    [ "$CT_TYPE" = "lxc" ] || [ "$CT_TYPE" = "lxc-libvirt" ] && IS_LXC=true
fi
grep -qa 'lxc' /proc/1/environ 2>/dev/null && IS_LXC=true
[ -d /dev/lxd ] || [ -d /var/lib/lxc ] && IS_LXC=true

if command -v docker &>/dev/null; then
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
        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-v2
    else
        log_info "Bare metal / VM — installing Docker Engine (official repo)..."
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

# ============================================================
# STEP 3: Database Password (idempotent — generate once, reuse)
# ============================================================
log_step "Step 3: Database Password"

mkdir -p "$KILLBILL_BASE"

ENV_DB_PASSWORD="${DB_PASSWORD:-}"

if [ -f "$KILLBILL_BASE/.db-credentials" ]; then
    # Existing database — the persisted password is the source of truth.
    # MariaDB only reads MARIADB_ROOT_PASSWORD on FIRST init (empty data dir),
    # so a new password here would be silently ignored by the live volume anyway.
    DB_PASSWORD=$(grep '^DB_PASSWORD=' "$KILLBILL_BASE/.db-credentials" | cut -d= -f2)
    if [ -n "$ENV_DB_PASSWORD" ] && [ "$ENV_DB_PASSWORD" != "$DB_PASSWORD" ]; then
        log_warn "Ignoring DB_PASSWORD env var — existing database already uses a different password"
        log_warn "(to reset it, destroy the volume first: docker compose down -v)"
    fi
    log_ok "Reusing existing DB password from $KILLBILL_BASE/.db-credentials"
else
    # Fresh install — use the provided password or generate one
    if [ -n "$ENV_DB_PASSWORD" ]; then
        DB_PASSWORD="$ENV_DB_PASSWORD"
        log_ok "Using DB_PASSWORD from environment"
    else
        DB_PASSWORD=$(openssl rand -hex 16)
        log_ok "Generated new DB password"
    fi
    echo "DB_PASSWORD=$DB_PASSWORD" > "$KILLBILL_BASE/.db-credentials"
    chmod 600 "$KILLBILL_BASE/.db-credentials"
    log_ok "Saved to $KILLBILL_BASE/.db-credentials"
fi

# ============================================================
# STEP 4: Write docker-compose.yml
# ============================================================
log_step "Step 4: Docker Compose File"

cat > "$KILLBILL_BASE/docker-compose.yml" << COMPOSE_EOF
services:
  db:
    image: killbill/mariadb:${MARIADB_VERSION}
    container_name: killbill-db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/mysql
    expose:
      - "3306"
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 60s

  killbill:
    image: killbill/killbill:${KILLBILL_VERSION}
    container_name: killbill
    restart: unless-stopped
    ports:
      - "${KILLBILL_PORT}:8080"
    depends_on:
      db:
        condition: service_healthy
    environment:
      KILLBILL_DAO_URL: jdbc:mysql://db:3306/killbill
      KILLBILL_DAO_USER: root
      KILLBILL_DAO_PASSWORD: ${DB_PASSWORD}
      JAVA_OPTS: ${JAVA_HEAP}

  kaui:
    image: killbill/kaui:${KAUI_VERSION}
    container_name: kaui
    restart: unless-stopped
    ports:
      - "${KAUI_PORT}:8080"
    depends_on:
      - killbill
    environment:
      KAUI_CONFIG_DAO_URL: jdbc:mysql://db:3306/kaui
      KAUI_CONFIG_DAO_USER: root
      KAUI_CONFIG_DAO_PASSWORD: ${DB_PASSWORD}
      KAUI_KILLBILL_URL: http://killbill:8080

volumes:
  db-data:
COMPOSE_EOF

chmod 600 "$KILLBILL_BASE/docker-compose.yml"
log_ok "Compose file written to $KILLBILL_BASE/docker-compose.yml"

# ============================================================
# STEP 5: Start the stack
# ============================================================
log_step "Step 5: Start Kill Bill stack"

cd "$KILLBILL_BASE"
docker compose up -d
log_ok "Containers started"

# ============================================================
# STEP 6: Health Check (engine + Kaui)
# ============================================================
log_step "Step 6: Health Check"

# Wait for the engine (Java/Tomcat — takes a minute or two on first boot).
# NOTE: we deliberately do NOT use /1.0/healthcheck here — Kill Bill starts
# "out of rotation" (a load-balancer signal) and only reports healthy after a
# manual putInRotation() via PUT /1.0/kb/admin/healthcheck. The definitive
# ready-signal is Tomcat's log line: "Server startup in N ms".
ENGINE_READY=false
for i in $(seq 1 50); do
    if docker logs killbill 2>&1 | grep -q "Server startup"; then
        log_ok "Kill Bill engine ready — Tomcat 'Server startup' detected (attempt $i)"
        ENGINE_READY=true
        break
    fi
    sleep 6
done
if [ "$ENGINE_READY" = false ]; then
    log_error "Kill Bill engine did not become ready after ~5 minutes"
    log_info "Recent logs:"
    docker logs killbill --tail 40 || true
    exit 1
fi

# Wait for Kaui (usually fast once the engine is up)
KAUI_READY=false
for i in $(seq 1 20); do
    if curl -sf "http://localhost:${KAUI_PORT}/" &>/dev/null; then
        log_ok "Kaui UI healthy (attempt $i)"
        KAUI_READY=true
        break
    fi
    sleep 5
done
if [ "$KAUI_READY" = false ]; then
    log_warn "Kaui UI did not respond within ~100s — it may still be warming up"
    log_info "Check with: docker logs kaui --tail 40"
fi

# ============================================================
# STEP 7: Verify containers
# ============================================================
log_step "Step 7: Verify"

docker ps --filter "name=killbill" --filter "name=kaui" \
    --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  KILL BILL — SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  Admin UI (Kaui):  http://${SERVER_IP}:${KAUI_PORT}"
echo "    Login:          admin"
echo "    Password:       password"
echo ""
echo "  Engine API:        http://${SERVER_IP}:${KILLBILL_PORT}"
echo "  API explorer:      http://${SERVER_IP}:${KILLBILL_PORT}/api.html"
echo ""
echo "  Config:            ${KILLBILL_BASE}/docker-compose.yml"
echo "  DB credentials:    ${KILLBILL_BASE}/.db-credentials"
echo "  Logs:              docker logs killbill | docker logs kaui"
echo ""
echo -e "${CYAN}  ── FIRST LOGIN ──${NC}"
echo "  Open the Kaui URL above and log in as admin / password."
echo "  Kaui will prompt you to create your first tenant"
echo "  (e.g. Name: custodian, API Key: custodian, API Secret: custodian)."
echo ""
echo -e "${CYAN}  ── MANAGEMENT ──${NC}"
echo "    docker compose -f ${KILLBILL_BASE}/docker-compose.yml ps"
echo "    docker compose -f ${KILLBILL_BASE}/docker-compose.yml logs -f"
echo "    docker compose -f ${KILLBILL_BASE}/docker-compose.yml down"
echo "    docker compose -f ${KILLBILL_BASE}/docker-compose.yml up -d"
echo ""
echo "  Re-running this script is safe (idempotent)."
echo ""
