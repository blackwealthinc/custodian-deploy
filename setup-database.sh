#!/bin/bash
# ============================================================================
# Custodian — Central Database Setup
# ============================================================================
# What this does:
#   Deploys PostgreSQL via Docker on a bare Ubuntu 22.04/24.04 server.
#   Creates the custodian database with all tables (customers, usage, servers).
#   Auto-generates a secure password if not provided.
#
# Prerequisites:
#   - Ubuntu 22.04 LTS or 24.04 LTS
#   - Root access
#   - Internet access
#
# Environment variables (all optional):
#   POSTGRES_PASSWORD  — database password (auto-generated if not set)
#   DB_NAME            — database name (default: custodian)
#   DB_USER            — database user (default: custodian)
#   DB_PORT            — PostgreSQL port (default: 5432)
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-database.sh | sudo bash
#
# Architecture: custodian-architecture-budget-proxy-scaling.md § 9
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

# ── Configuration ──
DB_NAME="${DB_NAME:-custodian}"
DB_USER="${DB_USER:-custodian}"
DB_PORT="${DB_PORT:-5432}"
SCHEMA_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/schema.sql"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    log_info "Generated database password: ${POSTGRES_PASSWORD:0:16}..."
fi

OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release | tr -d '"')
OS_VER=$(grep -oP 'VERSION_ID="?\K[0-9.]+' /etc/os-release)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}"
echo "  Custodian — Central Database Setup"
echo "  OS: $OS_ID $OS_VER | Host: $(hostname) | IP: $SERVER_IP"
echo -e "${NC}"

# ============================================================
# STEP 1: System Update & Docker
# ============================================================
log_step "Step 1: System Update & Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl

# ── Auto-detect Proxmox LXC ──
# docker-ce pulls containerd 1.7.x which triggers
# "ip_unprivileged_port_start: permission denied" inside LXC.
# docker.io ships containerd 1.6.x which works in LXC.
# See: research/proxmox-lxc-containerd-fix-plan.md
IS_LXC=false
if [ -f /run/systemd/container ]; then
    CT_TYPE=$(cat /run/systemd/container 2>/dev/null || echo "")
    [ "$CT_TYPE" = "lxc" ] || [ "$CT_TYPE" = "lxc-libvirt" ] && IS_LXC=true
fi
grep -qa 'lxc' /proc/1/environ 2>/dev/null && IS_LXC=true
[ -d /dev/lxd ] || [ -d /var/lib/lxc ] && IS_LXC=true

# Install Docker if missing
if ! command -v docker &>/dev/null; then
    if [ "$IS_LXC" = true ]; then
        # ── LXC path: Ubuntu's docker.io (containerd 1.6.x) ──
        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-v2
    else
        # ── Bare metal / cloud VM path: official Docker repo ──
        log_info "Installing Docker Engine (official repo)..."
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
# STEP 2: Deploy PostgreSQL
# ============================================================
log_step "Step 2: Deploy PostgreSQL"

mkdir -p /opt/custodian-db/data /opt/custodian-db/init

# Download schema
curl -sS -o /opt/custodian-db/init/01-schema.sql "$SCHEMA_URL"
log_ok "Schema downloaded"

# Stop existing container if re-running (idempotent)
docker rm -f custodian-postgres 2>/dev/null || true

docker run -d \
  --name custodian-postgres \
  --restart unless-stopped \
  -e POSTGRES_DB="$DB_NAME" \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -p "127.0.0.1:${DB_PORT}:5432" \
  -v /opt/custodian-db/data:/var/lib/postgresql/data \
  -v /opt/custodian-db/init:/docker-entrypoint-initdb.d:ro \
  postgres:16-alpine

log_ok "PostgreSQL container started (port $DB_PORT)"

# ============================================================
# STEP 3: Wait for PostgreSQL to be ready
# ============================================================
log_step "Step 3: Wait for PostgreSQL"

for i in $(seq 1 30); do
    if docker exec custodian-postgres pg_isready -U "$DB_USER" -d "$DB_NAME" &>/dev/null; then
        log_ok "PostgreSQL ready (attempt $i)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log_error "PostgreSQL failed to start after 30 attempts"
        docker logs custodian-postgres --tail 30
        exit 1
    fi
    sleep 2
done

# ============================================================
# STEP 4: Update self-server row
# ============================================================
log_step "Step 4: Register Database Server"

docker exec custodian-postgres psql -U "$DB_USER" -d "$DB_NAME" -c "
  UPDATE servers 
  SET ip_address = '$SERVER_IP', 
      status = 'active',
      server_name = 'db-$(hostname)',
      spec = 'PostgreSQL 16 / Docker',
      monthly_cost = 0
  WHERE server_name = 'budget-proxy';
" 2>/dev/null || log_warn "Could not update server row (may already exist)"

# If no row exists (schema loaded differently), insert one
docker exec custodian-postgres psql -U "$DB_USER" -d "$DB_NAME" -c "
  INSERT INTO servers (server_name, ip_address, status, max_customers, spec)
  VALUES ('db-$(hostname)', '$SERVER_IP', 'active', 1, 'PostgreSQL 16 / Docker')
  ON CONFLICT (server_name) DO NOTHING;
" 2>/dev/null || true

log_ok "Server registered in database"

# ============================================================
# STEP 5: Save credentials
# ============================================================
log_step "Step 5: Save Credentials"

cat > /opt/custodian-db/.db-credentials << EOF
# Custodian Database Credentials
# Generated: $(date)
# Keep this file secure. Do not commit to version control.
DB_HOST=localhost
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_URL=postgresql://${DB_USER}:${POSTGRES_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}
EOF
chmod 600 /opt/custodian-db/.db-credentials
log_ok "Credentials saved to /opt/custodian-db/.db-credentials (chmod 600)"

# ============================================================
# STEP 6: Verify Tables
# ============================================================
log_step "Step 6: Verify Tables"

TABLES=$(docker exec custodian-postgres psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;" 2>/dev/null)
log_info "Tables created:"
echo "$TABLES" | while read t; do echo "    - $t"; done

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  CUSTODIAN DATABASE — SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  PostgreSQL:  localhost:${DB_PORT}"
echo "  Database:    ${DB_NAME}"
echo "  User:        ${DB_USER}"
echo "  Password:    ${POSTGRES_PASSWORD:0:16}... (saved to /opt/custodian-db/.db-credentials)"
echo ""
echo "  Connection string:"
echo "    postgresql://${DB_USER}:***@localhost:${DB_PORT}/${DB_NAME}"
echo ""
echo "  Verify:"
echo "    docker exec custodian-postgres psql -U ${DB_USER} -d ${DB_NAME} -c '\\dt'"
echo ""
