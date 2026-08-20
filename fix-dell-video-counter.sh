#!/bin/bash
# ============================================================================
# Custodian — Deploy Custodian Video + Custodian Budget pipes + hide models
# Run ON THE DELL (192.168.50.250).
# ============================================================================
# 1. Deploys "Custodian Video" and "Custodian Budget" pipe Functions (downloaded
#    from GitHub, not embedded — single source of truth).
# 2. Hides the 4 stale provider-named models (deepseek-chat, deepseek-v4-flash,
#    deepseek-v4-pro, gpt-image-2-hd) that leak provider names in the dropdown.
# 3. Restricts the OpenAI connections' model_ids so those models (and the new
#    custodian-video model) do NOT get re-fetched into the dropdown on restart.
#    The old value is backed up for rollback.
#
# Usage (on the Dell):  curl -s <this-script-url> | sudo -E bash
# ============================================================================
set -euo pipefail

WEBUI_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then
    echo "ERROR: No WebUI container found (looking for *-webui)"
    docker ps --format '  - {{.Names}}' 2>/dev/null || echo "  (Docker not accessible)"
    exit 1
fi
echo "Found WebUI container: $WEBUI_CONTAINER"

WEBUI_PORT="${WEBUI_PORT:-3000}"
BASE="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/functions"

echo ""
echo "=== Step 1: Download pipe function code from GitHub ==="
curl -s -o /tmp/custodian_video_pipe.py  "$BASE/custodian-video-pipe.py"
curl -s -o /tmp/custodian_budget_pipe.py "$BASE/custodian-budget-pipe.py"
[ -s /tmp/custodian_video_pipe.py ]  || { echo "ERROR: custodian-video-pipe.py download failed"; exit 1; }
[ -s /tmp/custodian_budget_pipe.py ] || { echo "ERROR: custodian-budget-pipe.py download failed"; exit 1; }
echo "OK: downloaded both function files"

echo ""
echo "=== Step 2: Write DB fix script ==="
cat > /tmp/fix_video_counter.py << 'PYEOF'
import sqlite3, json, time, uuid

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())
changes = []

def upsert_pipe(name, pipe_id_ns, content_path, description):
    pipe_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, pipe_id_ns))
    meta = json.dumps({
        "description": description,
        "manifest": {"name": name, "version": "1.0.0"},
    })
    with open(content_path, 'r') as f:
        content = f.read()
    existing = conn.execute("SELECT id FROM function WHERE id=?", (pipe_id,)).fetchone()
    if existing:
        conn.execute(
            "UPDATE function SET name=?, type=?, content=?, meta=?, is_active=?, is_global=?, updated_at=? WHERE id=?",
            (name, 'pipe', content, meta, True, True, now, pipe_id),
        )
        changes.append(f"UPDATED {name} pipe")
    else:
        conn.execute(
            "INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (pipe_id, None, name, 'pipe', content, meta, '{}', True, True, now, now),
        )
        changes.append(f"CREATED {name} pipe")

upsert_pipe('Custodian Video', 'custodian-video-pipe', '/tmp/custodian_video_pipe.py',
             'Creates a short video from your description.')
upsert_pipe('Custodian Budget', 'custodian-budget-pipe', '/tmp/custodian_budget_pipe.py',
             'Shows how much you have used this month.')

# 2. Hide stale provider-named models (API-fetched rows only — base_model_id IS NULL).
stale = conn.execute(
    "SELECT id, name FROM model WHERE name IN "
    "('deepseek-chat','deepseek-v4-flash','deepseek-v4-pro','gpt-image-2-hd') AND base_model_id IS NULL"
).fetchall()
for row in stale:
    conn.execute("DELETE FROM model WHERE id=?", (row[0],))
    changes.append(f"DELETED stale model {row[1]} (id={row[0][:8]}...)")
    print(f"DELETED stale model {row[1]}")
if not stale:
    print("OK: no stale models found (already clean)")

# 3. Restrict OpenAI connection model_ids (index-keyed) so stale models + the new
#    custodian-video model are NOT re-fetched into the dropdown. Back up old value first.
old = conn.execute("SELECT value FROM config WHERE key='openai.api_configs'").fetchone()
if old:
    bak_key = f"openai.api_configs.bak.{now}"
    conn.execute(
        "INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (bak_key, old[0]),
    )
    changes.append(f"BACKED UP old openai.api_configs -> {bak_key}")

# Connection 1 = LiteLLM (vision/images) — restrict to dashscope-vision so the
# 4 stale provider-named models (deepseek-*, gpt-image-2-hd) are NOT re-fetched.
# Connection 0 (hermes) is left untouched: it serves only "hermes-backend",
# which the "Custodian" model aliases — restricting it would be a no-op.
new_api_configs = json.dumps({
    "1": {"model_ids": ["dashscope-vision"]},
})
conn.execute(
    "INSERT INTO config (key, value) VALUES ('openai.api_configs', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    (new_api_configs,),
)
changes.append("SET openai.api_configs -> {1: dashscope-vision}")

conn.commit()
conn.close()

print(f"\n=== DONE: {len(changes)} changes ===")
for c in changes:
    print(f"  - {c}")
PYEOF

echo ""
echo "=== Step 3: Copy files into container and run ==="
docker cp /tmp/custodian_video_pipe.py  "$WEBUI_CONTAINER":/tmp/
docker cp /tmp/custodian_budget_pipe.py "$WEBUI_CONTAINER":/tmp/
docker cp /tmp/fix_video_counter.py "$WEBUI_CONTAINER":/tmp/
docker exec "$WEBUI_CONTAINER" python3 /tmp/fix_video_counter.py 2>&1

echo ""
echo "=== Step 4: Restart WebUI to refresh model/function cache ==="
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
echo "=== Step 5: Verify ==="
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
print('--- Functions (pipes) ---')
for r in c.execute(\"SELECT name, type, is_active, is_global FROM function WHERE type='pipe'\").fetchall():
    print(f'  {r[0]:20s} type={r[1]:5s} active={r[2]} global={r[3]}')
print('--- Models in dropdown ---')
for r in c.execute('SELECT name, base_model_id FROM model ORDER BY name').fetchall():
    print(f'  {r[0]:20s} base={r[1] or \"NULL\"}')
c.close()
" 2>&1

echo ""
echo "=== DONE ==="
echo "Custodian Video + Custodian Budget deployed. Stale models hidden. Connection model_ids restricted."
