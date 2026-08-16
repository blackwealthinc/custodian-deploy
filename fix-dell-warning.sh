#!/bin/bash
# fix-dell-warning.sh
# Run ON THE DELL (192.168.50.250) as root.
# Adds the 3-day image-deletion warning to the "Custodian" model description.
# Idempotent — safe to re-run.

set -euo pipefail

# Auto-detect WebUI container (supports any CUSTOMER_ID: admin-webui, custodian-webui, etc.)
WEBUI_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then
    echo "ERROR: No WebUI container found (looking for *-webui)"
    echo "Running containers:"
    docker ps --format '  - {{.Names}}' 2>/dev/null || echo "  (Docker not accessible)"
    exit 1
fi
echo "Found WebUI container: $WEBUI_CONTAINER"

WEBUI_PORT="${WEBUI_PORT:-3000}"

echo "=== Fix Dell: add 3-day image-deletion warning to 'Custodian' ==="

cat > /tmp/add_warning.py << 'PYEOF'
import sqlite3, json, time

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())

new_desc = ("Your AI assistant for questions, writing, and everyday help. "
            "To create images, switch to 'Custodian Images'. "
            "Images are kept for 3 days, then removed automatically.")

row = conn.execute(
    "SELECT id, meta FROM model WHERE name='Custodian' AND base_model_id IS NOT NULL"
).fetchone()
if not row:
    print("WARNING: 'Custodian' model not found — skipping")
else:
    model_id, meta_json = row
    meta = json.loads(meta_json) if meta_json else {}
    meta["description"] = new_desc
    conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?",
                 (json.dumps(meta), now, model_id))
    conn.commit()
    print("UPDATED: 'Custodian' description now includes the 3-day warning")

conn.close()
PYEOF

docker cp /tmp/add_warning.py "$WEBUI_CONTAINER":/tmp/
OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/add_warning.py 2>&1)
echo "$OUTPUT"
docker exec "$WEBUI_CONTAINER" rm -f /tmp/add_warning.py 2>/dev/null || true
rm -f /tmp/add_warning.py

# Restart WebUI to refresh the cached model list (description is cached)
echo ""
echo "Restarting WebUI to refresh the model cache..."
docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1

for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WEBUI_PORT}" 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "WebUI restarted (HTTP $CODE)"
        break
    fi
    [ "$i" -eq 30 ] && echo "WARNING: WebUI slow to restart"
    sleep 2
done

echo ""
echo "=== VERIFY ==="
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute(\"SELECT json_extract(meta,'\$.description') FROM model WHERE name='Custodian' AND base_model_id IS NOT NULL\").fetchone()
print('Custodian description:', r[0] if r else 'NOT FOUND')
c.close()
" 2>&1

echo ""
echo "=== DONE ==="
echo "'Custodian' now warns that images are kept for 3 days."
