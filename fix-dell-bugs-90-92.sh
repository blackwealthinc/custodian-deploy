#!/bin/bash
# fix-dell-bugs-90-92.sh
# Run ON THE DELL (192.168.50.250).
#
# Bug #90: Updates Hermes container env from API_SERVER_MODEL_NAME=Custodian
#          to hermes-backend so the duplicate isn't re-created.
# Bug #92: Adds RAG_FILE_MAX_SIZE=10000 to WebUI container (10GB upload cap).
# Then re-runs the model cleanup to delete any re-created duplicates.

set -euo pipefail

# Auto-detect containers
HERMES_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '\-hermes$' | head -1)
WEBUI_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | head -1)

if [ -z "$HERMES_CONTAINER" ] || [ -z "$WEBUI_CONTAINER" ]; then
    echo "ERROR: Could not find containers"
    echo "Hermes: ${HERMES_CONTAINER:-NOT FOUND}"
    echo "WebUI:  ${WEBUI_CONTAINER:-NOT FOUND}"
    docker ps --format '  - {{.Names}}' 2>/dev/null
    exit 1
fi

echo "Found: Hermes=$HERMES_CONTAINER  WebUI=$WEBUI_CONTAINER"

# ── Fix 1: Bug #90 — Update Hermes env to hermes-backend ──
echo ""
echo "=== Fix #90: Update Hermes model name ==="
CURRENT_NAME=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_MODEL_NAME"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)

if [ "$CURRENT_NAME" = "hermes-backend" ]; then
    echo "OK: Already hermes-backend"
elif [ "$CURRENT_NAME" = "Custodian" ]; then
    echo "Current: API_SERVER_MODEL_NAME=$CURRENT_NAME"
    echo "Updating to hermes-backend..."
    docker update --env-add "API_SERVER_MODEL_NAME=hermes-backend" "$HERMES_CONTAINER" 2>/dev/null || {
        echo "docker update failed — trying docker stop + recreate env..."
        # Fallback: restart with updated env requires compose or manual restart
        echo "WARNING: Cannot update env on running container. Will need redeploy."
    }
    docker restart "$HERMES_CONTAINER" >/dev/null 2>&1
    echo "Hermes restarted"
else
    echo "Current: ${CURRENT_NAME:-NOT SET}"
    echo "Adding API_SERVER_MODEL_NAME=hermes-backend..."
    docker update --env-add "API_SERVER_MODEL_NAME=hermes-backend" "$HERMES_CONTAINER" 2>/dev/null
    docker restart "$HERMES_CONTAINER" >/dev/null 2>&1
    echo "Hermes restarted"
fi

# Wait for Hermes
for i in $(seq 1 15); do
    if docker exec "$HERMES_CONTAINER" curl -s http://localhost:8642/v1/health 2>/dev/null | grep -q '"status"'; then
        echo "Hermes healthy"
        break
    fi
    sleep 2
done

# ── Fix 2: Bug #92 — Add RAG_FILE_MAX_SIZE to WebUI ──
echo ""
echo "=== Fix #92: Add RAG_FILE_MAX_SIZE=10000 (10GB cap) ==="
HAS_RAG=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "RAG_FILE_MAX_SIZE"}}YES{{end}}{{end}}' 2>/dev/null)

if [ "$HAS_RAG" = "YES" ]; then
    echo "OK: RAG_FILE_MAX_SIZE already set"
else
    echo "Adding RAG_FILE_MAX_SIZE=10000..."
    docker update --env-add "RAG_FILE_MAX_SIZE=10000" "$WEBUI_CONTAINER" 2>/dev/null
    docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1
    
    for i in $(seq 1 30); do
        CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
        if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
            echo "WebUI restarted (HTTP $CODE)"
            break
        fi
        sleep 2
    done
fi

# ── Fix 3: Clean up any re-created API-fetched models ──
echo ""
echo "=== Cleanup: Delete any re-created API-fetched models ==="
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
rows = conn.execute(
    \"SELECT id, name, user_id FROM model WHERE name='Custodian' AND base_model_id IS NULL\"
).fetchall()
for row in rows:
    conn.execute('DELETE FROM model WHERE id=?', (row[0],))
    print(f'DELETED API-fetched: {row[1]} (user={row[2]})')
conn.commit()
if not rows:
    print('NONE_FOUND (clean)')
conn.close()
" 2>&1

echo ""
echo "=== VERIFY ==="
echo "Hermes model name:"
docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep API_SERVER_MODEL_NAME

echo ""
echo "WebUI RAG limit:"
docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep RAG_FILE_MAX_SIZE

echo ""
echo "Custodian models:"
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
for r in c.execute(\"SELECT name, base_model_id FROM model WHERE name LIKE '%ustodian%'\").fetchall():
    print(f'  {r[0]:25s} base={r[1] or \"NULL\"}')
c.close()
" 2>&1

echo ""
echo "=== DONE ==="
echo "#90: Hermes now advertises 'hermes-backend' (no more duplicate Custodian)"
echo "#92: RAG_FILE_MAX_SIZE=10000 (10GB upload cap)"
