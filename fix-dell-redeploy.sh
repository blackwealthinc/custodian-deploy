#!/bin/bash
# fix-dell-redeploy.sh (v2 — auto-detects data directory)
# Run ON THE DELL (192.168.50.250).
#
# Re-deploys the Dell with the corrected docker-compose from GitHub.
#
# Fixes:
#   Bug #90: API_SERVER_MODEL_NAME=hermes-backend (no duplicate Custodian)
#   Bug #91: image generation routed to LiteLLM (gpt-image-2-hd)
#   Bug #92: RAG_FILE_MAX_SIZE=10000 (10GB upload cap)
#   Bug #93: ENABLE_PERSISTENT_CONFIG=false (env vars win over stale DB)
#   Bug #94: auto-detect data dir (was hardcoded /home/custodian → data loss)
#
# WHY auto-detect (Bug #94 fix):
#   The original deployment used CUSTODIAN_HOME=/data, so the compose's
#   relative volume ./webui-data resolved to /data/webui-data. Earlier fix
#   scripts hardcoded cd /home/custodian, silently switching the container
#   to a fresh empty DB. We now SCAN for the real webui.db and use its dir.
#
#   Source: https://docs.docker.com/compose/compose-file/05-services/#volumes
#   "Relative paths are resolved from the directory containing the Compose file."

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

echo "=== Fix Dell: Re-deploy (v2 — auto-detect data dir) ==="

# 1. Find existing containers (for key extraction, BEFORE recreation)
HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-hermes$' | grep -v '^custodian-' | head -1)
WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | grep -v '^custodian-' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'webui' | head -1); fi
if [ -z "$HERMES_CONTAINER" ]; then HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'hermes' | head -1); fi
echo "Found: Hermes=$HERMES_CONTAINER  WebUI=$WEBUI_CONTAINER"

# 2. Extract existing keys (do NOT regenerate)
API_SERVER_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$API_SERVER_KEY" ]; then
    API_SERVER_KEY=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute('SELECT value FROM config WHERE key=\\\"openai.api_keys\\\"').fetchone()
if r:
    keys = json.loads(r[0])
    print(keys[0] if keys else '')
c.close()
" 2>/dev/null)
fi
if [ -z "$API_SERVER_KEY" ]; then echo "ERROR: no API_SERVER_KEY"; exit 1; fi
echo "API_SERVER_KEY: ${API_SERVER_KEY:0:8}..."

CUST_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "IMAGES_OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
WEBUI_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "WEBUI_SECRET_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$CUST_KEY" ]; then echo "ERROR: no CUSTOMER_API_KEY"; exit 1; fi
if [ -z "$WEBUI_KEY" ]; then echo "WARN: no WEBUI_SECRET_KEY, generating new (users re-login)"; WEBUI_KEY=$(openssl rand -hex 32); fi
echo "CUST_KEY: ${CUST_KEY:0:8}..."

# 3. AUTO-DETECT the real data directory (Bug #94 fix)
#    Scan common locations; pick the webui.db with the most models.
CUSTODIAN_HOME=""
MAX_MODELS=-1
for DIR in /data /home/custodian /home/admin /opt/custodian; do
    DB="$DIR/webui-data/webui.db"
    if [ -f "$DB" ]; then
        COUNT=$(python3 -c "import sqlite3; c=sqlite3.connect('$DB'); print(c.execute('SELECT COUNT(*) FROM model').fetchone()[0]); c.close()" 2>/dev/null || echo "0")
        COUNT=${COUNT:-0}
        echo "  scan: $DIR/webui-data/webui.db → models=$COUNT"
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

# 4. Download the corrected compose INTO the data directory
cd "$CUSTODIAN_HOME"
curl -sS -o docker-compose.custodian-factory.yml "${COMPOSE_URL}?$(date +%s)"
echo "Compose downloaded to $CUSTODIAN_HOME"

# 5. Remove stale WebUI containers holding port 3000
echo "Removing stale WebUI containers..."
for OLD in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'webui' | grep -v '^admin-webui$'); do
    echo "  Removing: $OLD"
    docker rm -f "$OLD" 2>/dev/null || echo "  (already gone)"
done

# 6. Re-create containers with correct env + correct volume path
echo "Re-deploying..."
CUSTOMER_ID="admin" \
  API_SERVER_KEY="$API_SERVER_KEY" \
  WEBUI_SECRET_KEY="$WEBUI_KEY" \
  CUSTOMER_API_KEY="$CUST_KEY" \
  BUDGET_PROXY_URL="http://100.64.0.1:4000/v1" \
  PORT="8642" WEBUI_PORT="3000" \
  docker compose -p admin -f docker-compose.custodian-factory.yml up -d --force-recreate 2>&1

# 7. Wait for WebUI
echo "Waiting for WebUI..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then echo "WebUI ready ($CODE)"; break; fi
    sleep 3
done

# 8. Clean up any API-fetched duplicate (base_model_id IS NULL)
echo "Cleaning API-fetched models..."
docker exec admin-webui python3 -c "
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

# 9. Verify
echo ""
echo "=== VERIFY ==="
echo "Data dir: $CUSTODIAN_HOME"
echo "Models:"
docker exec admin-webui python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
for r in c.execute('SELECT name, base_model_id FROM model ORDER BY name').fetchall():
    print(f'  {r[0]} base={r[1]}')
print(f'Total chats:', c.execute('SELECT COUNT(*) FROM chat').fetchone()[0])
c.close()
" 2>&1
echo "ENABLE_PERSISTENT_CONFIG:"
docker exec admin-webui printenv ENABLE_PERSISTENT_CONFIG 2>&1
echo "API_SERVER_MODEL_NAME:"
docker inspect admin-hermes --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_MODEL_NAME"}}{{println .}}{{end}}{{end}}' 2>/dev/null
echo ""
echo "=== DONE ==="
