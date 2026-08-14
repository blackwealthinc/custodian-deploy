#!/bin/bash
# fix-dell-redeploy.sh (v3 — complete Dell fix: redeploy + model routing + cleanup + warning)
# Run ON THE DELL (192.168.50.250) as root.
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-dell-redeploy.sh | sudo bash
#
# Fixes (all verified against live Dell 2026-08-13):
#   Bug #95: OPENAI_API_BASE_URL (singular) dropped LiteLLM -> plural OPENAI_API_BASE_URLS/KEYS
#   Bug #96: cleanup timer pointed at /home/custodian (empty) -> /data/webui-data (real)
#   Bug #97: "Custodian" base_model_id='Custodian' dangling -> 'hermes-backend'
#   Bug #99: RAG_FILE_MAX_SIZE=10000 (10GB/file) -> 100 (100MB/file) + 10GB TOTAL cap
#   Bug #104: removed dead Image Deletion Warning filter (filters can't hook image gen;
#             the model description is the reliable 3-day warning)
#
# WHY auto-detect (Bug #94 fix):
#   Original deployment used CUSTODIAN_HOME=/data, so the compose's relative
#   volume ./webui-data resolves to /data/webui-data. Earlier scripts hardcoded
#   cd /home/custodian, silently switching to a fresh empty DB.
#   Source: https://docs.docker.com/compose/compose-file/05-services/#volumes
#   "Relative paths are resolved from the directory containing the Compose file."

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

echo "=== Fix Dell: Redeploy + model routing + cleanup (v3) ==="

# ── 1. Find existing containers (for key extraction, BEFORE recreation) ──
HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-hermes$' | grep -v '^custodian-' | head -1)
WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | grep -v '^custodian-' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'webui' | head -1); fi
if [ -z "$HERMES_CONTAINER" ]; then HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'hermes' | head -1); fi
echo "Found: Hermes=$HERMES_CONTAINER  WebUI=$WEBUI_CONTAINER"

# ── 2. Extract existing keys (do NOT regenerate — preserves sessions + auth) ──
API_SERVER_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$API_SERVER_KEY" ]; then
    API_SERVER_KEY=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute('SELECT value FROM config WHERE key=?', ('openai.api_keys',)).fetchone()
if r:
    keys = json.loads(r[0])
    print(keys[0] if keys else '')
c.close()
" 2>/dev/null)
fi
if [ -z "$API_SERVER_KEY" ]; then echo "ERROR: no API_SERVER_KEY"; exit 1; fi
echo "API_SERVER_KEY: ${API_SERVER_KEY:0:8}..."

CUST_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "IMAGES_OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
# Fallback: Hermes container's OPENAI_API_KEY = ${CUSTOMER_API_KEY} (same key)
if [ -z "$CUST_KEY" ]; then
    CUST_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
fi
WEBUI_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "WEBUI_SECRET_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$CUST_KEY" ]; then echo "ERROR: no CUSTOMER_API_KEY"; exit 1; fi
if [ -z "$WEBUI_KEY" ]; then echo "WARN: no WEBUI_SECRET_KEY, generating new (users re-login)"; WEBUI_KEY=$(openssl rand -hex 32); fi
echo "CUST_KEY: ${CUST_KEY:0:8}..."

# ── 3. AUTO-DETECT the real data directory (Bug #94 fix) ──
CUSTODIAN_HOME=""
MAX_MODELS=-1
for DIR in /data /home/custodian /home/admin /opt/custodian; do
    DB="$DIR/webui-data/webui.db"
    if [ -f "$DB" ]; then
        COUNT=$(python3 -c "import sqlite3; c=sqlite3.connect('$DB'); print(c.execute('SELECT COUNT(*) FROM model').fetchone()[0]); c.close()" 2>/dev/null || echo "0")
        COUNT=${COUNT:-0}
        echo "  scan: $DIR/webui-data/webui.db -> models=$COUNT"
        if [ "$COUNT" -gt "$MAX_MODELS" ] 2>/dev/null; then
            MAX_MODELS="$COUNT"
            CUSTODIAN_HOME="$DIR"
        fi
    fi
done
if [ -z "$CUSTODIAN_HOME" ]; then
    echo "ERROR: could not find an existing webui.db. Aborting (refusing to create empty)."
    exit 1
fi
echo "Using data directory: $CUSTODIAN_HOME (models=$MAX_MODELS)"

# ── 4. Download the corrected compose INTO the data directory ──
cd "$CUSTODIAN_HOME"
curl -sS -o docker-compose.custodian-factory.yml "${COMPOSE_URL}?$(date +%s)"
echo "Compose downloaded to $CUSTODIAN_HOME"

# ── 5. Remove stale containers (webui holding port 3000 + orphaned hermes) ──
echo "Removing stale containers..."
for OLD in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'webui' | grep -v "^${WEBUI_CONTAINER}$"); do
    echo "  Removing webui: $OLD"
    docker rm -f "$OLD" 2>/dev/null || echo "  (already gone)"
done
for OLD in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'hermes' | grep -v "^${HERMES_CONTAINER}$"); do
    echo "  Removing hermes: $OLD"
    docker rm -f "$OLD" 2>/dev/null || echo "  (already gone)"
done

# ── 6. Re-create containers with correct env + correct volume path ──
echo "Re-deploying..."
CUSTOMER_ID="admin" \
  API_SERVER_KEY="$API_SERVER_KEY" \
  WEBUI_SECRET_KEY="$WEBUI_KEY" \
  CUSTOMER_API_KEY="$CUST_KEY" \
  BUDGET_PROXY_URL="http://100.64.0.1:4000/v1" \
  PORT="8642" WEBUI_PORT="3000" \
  docker compose -p admin -f docker-compose.custodian-factory.yml up -d --force-recreate 2>&1

# ── 7. Wait for WebUI ──
echo "Waiting for WebUI..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then echo "WebUI ready ($CODE)"; break; fi
    sleep 3
done

# ── 8. Fix dangling base_model_id (Bug #97) ──
echo "Fixing Custodian base_model_id -> hermes-backend..."
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
n = c.execute(\"UPDATE model SET base_model_id='hermes-backend' WHERE name='Custodian' AND base_model_id='Custodian'\").rowcount
c.commit()
print(f'FIXED base_model_id: {n} row(s)')
c.close()
" 2>&1

# ── 9. Clean up API-fetched duplicate "Custodian" (base_model_id IS NULL) ──
echo "Cleaning API-fetched models..."
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
rows = c.execute(\"SELECT id, name FROM model WHERE name='Custodian' AND base_model_id IS NULL\").fetchall()
for r in rows:
    c.execute('DELETE FROM model WHERE id=?', (r[0],))
    print(f'DELETED: {r[1]}')
c.commit()
if not rows: print('CLEAN')
c.close()
" 2>&1

# ── 10. Install cleanup script + timer (Bug #96 + #99: correct path + 10GB cap) ──
echo "Installing cleanup script + timer..."
cat > /usr/local/bin/custodian-cleanup.sh << 'SCRIPTEOF'
#!/bin/bash
set -uo pipefail

# Auto-detect the data dir (never hardcode — Bug #94/#96 lesson)
UPLOADS_DIR="${CUSTODIAN_DATA_DIR:-/data/webui-data}/uploads"
[ -d "$UPLOADS_DIR" ] || exit 0

MAX_BYTES=$((10 * 1024 * 1024 * 1024))   # 10 GB total

# 1) generated images older than 3 days
find "$UPLOADS_DIR" -name '*_generated-image.*' -mtime +3 -delete 2>/dev/null || true

# 2) other uploads older than 30 days
find "$UPLOADS_DIR" ! -name '*_generated-image.*' -mtime +30 -delete 2>/dev/null || true

# 3) enforce 10 GB total — delete oldest first until under cap
total=$(du -sb "$UPLOADS_DIR" 2>/dev/null | awk '{print $1}')
total=${total:-0}
if [ "$total" -gt "$MAX_BYTES" ]; then
  find "$UPLOADS_DIR" -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | while IFS=' ' read -r _ f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        rm -f "$f" 2>/dev/null || true
        total=$((total - sz))
        if [ "$total" -le "$MAX_BYTES" ]; then break; fi
      done
fi
SCRIPTEOF
chmod +x /usr/local/bin/custodian-cleanup.sh

cat > /etc/systemd/system/custodian-cleanup.service << UNITEOF
[Unit]
Description=Custodian — cleanup old images/uploads + enforce 10 GB cap
[Service]
Type=oneshot
Environment=CUSTODIAN_DATA_DIR=${CUSTODIAN_HOME}/webui-data
ExecStart=/usr/local/bin/custodian-cleanup.sh
UNITEOF

cat > /etc/systemd/system/custodian-cleanup.timer << 'UNITEOF'
[Unit]
Description=Hourly Custodian cleanup
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
systemctl enable --now custodian-cleanup.timer
echo "Cleanup timer installed (target: ${CUSTODIAN_HOME}/webui-data/uploads)"

# ── 11. Remove stale Image Deletion Warning filter (Bug #104 — filter can't fire for image gen) ──
echo "Removing stale Image Deletion Warning filter (if present)..."
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
n = c.execute(\"DELETE FROM function WHERE name='Image Deletion Warning'\").rowcount
c.commit()
print(f'REMOVED {n} stale filter(s)')
c.close()
" 2>&1 || true

# ── 12. Restart WebUI once to reload models + filters ──
echo "Restarting WebUI to reload models + filters..."
docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then echo "WebUI restarted ($CODE)"; break; fi
    sleep 2
done

# ── 13. Verify ──
echo ""
echo "=== VERIFY ==="
echo "Data dir: $CUSTODIAN_HOME"
echo "Models:"
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
for r in c.execute('SELECT name, base_model_id FROM model ORDER BY name').fetchall():
    print(f'  {r[0]:20s} base={r[1] or \"NULL\"}')
print(f'Chats:', c.execute('SELECT COUNT(*) FROM chat').fetchone()[0])
c.close()
" 2>&1
echo "Functions (filters):"
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
for r in c.execute('SELECT name, type, is_active FROM function').fetchall():
    print(f'  {r[0]} ({r[1]}) active={r[2]}')
c.close()
" 2>&1
echo "Env (must be PLURAL + RAG 100):"
docker exec "$WEBUI_CONTAINER" printenv OPENAI_API_BASE_URLS 2>&1
docker exec "$WEBUI_CONTAINER" printenv OPENAI_API_KEYS 2>&1 | sed -E 's/(sk-|b72).*/REDACTED/'
docker exec "$WEBUI_CONTAINER" printenv RAG_FILE_MAX_SIZE 2>&1
echo "Cleanup timer:"
systemctl is-enabled custodian-cleanup.timer 2>&1
systemctl is-active custodian-cleanup.timer 2>&1
echo ""
echo "=== DONE ==="
