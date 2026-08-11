#!/bin/bash
# fix-dell-models.sh
# Run ON THE DELL (192.168.50.250) as root.
# Fixes:
#   1. Deletes API-fetched Custodian model (the one Hermes auto-creates)
#   2. Creates Custodian Images model if missing
#   3. Fixes image_generation.openai.api_key to use custodian key
#   4. Ensures Custodian workspace model has NO image_generation capability
#   5. Wires image_generation and gpt-image-2-hd to LiteLLM URL

set -euo pipefail

WEBUI_CONTAINER="custodian-webui"
WEBUI_PORT="${WEBUI_PORT:-3000}"

echo "=== Fix Dell: Custodian Models + Image Generation ==="

cat > /tmp/fix_dell_models.py << 'PYEOF'
import sqlite3, json, os, time, uuid

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())
changes = []

# ── 1. DELETE API-fetched Custodian model (base_model_id IS NULL) ──
# This is the Hermes-auto-discovered model with ALL capabilities
# (code_interpreter, terminal, etc.) — we do NOT want users seeing this.
api_fetched = conn.execute(
    "SELECT id, name, user_id, base_model_id FROM model WHERE name='Custodian' AND base_model_id IS NULL"
).fetchall()
for row in api_fetched:
    conn.execute("DELETE FROM model WHERE id=?", (row[0],))
    changes.append(f"DELETED API-fetched Custodian model (id={row[0][:8]}... user={row[2]})")
    print(f"DELETED API-fetched Custodian model id={row[0][:8]}...")

if not api_fetched:
    print("OK: No API-fetched Custodian model found (already clean)")

# ── 2. Ensure Custodian workspace model has clean capabilities ──
# NO image_generation — that's for Custodian Images model only
custodian_meta = json.dumps({
    "capabilities": {
        "web_search": True,
        "vision": True
    },
    "description": "Custodian AI — Hermes + DeepSeek via Budget Proxy. For images, switch to 'Custodian Images' model."
})

workspace = conn.execute(
    "SELECT id, meta FROM model WHERE name='Custodian' AND base_model_id IS NOT NULL"
).fetchone()

if workspace:
    old_meta = json.loads(workspace[1]) if workspace[1] else {}
    old_caps = old_meta.get('capabilities', {})
    if old_caps.get('image_generation'):
        conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?",
            (custodian_meta, now, workspace[0]))
        changes.append("REMOVED image_generation from Custodian workspace model")
        print("FIXED: Removed image_generation from Custodian (image-only model is 'Custodian Images')")
    else:
        # Still update to ensure description is current
        conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?",
            (custodian_meta, now, workspace[0]))
        print("OK: Custodian model already clean")
else:
    # Create it
    model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-model'))
    conn.execute(
        "INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)",
        (model_id, '', 'Custodian', 'Custodian', '{}', custodian_meta, now, now))
    changes.append("CREATED Custodian workspace model")
    print("CREATED: Custodian workspace model")

# ── 3. UPSERT Custodian Images model ──
image_model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-images'))
image_meta = json.dumps({
    "capabilities": {
        "image_generation": True
    },
    "description": "DALL-E HD image generation via LiteLLM. Images auto-deleted after 3 days. Save important ones locally."
})

existing_img = conn.execute(
    "SELECT id FROM model WHERE name='Custodian Images'"
).fetchone()

if existing_img:
    conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?",
        (image_meta, now, existing_img[0]))
    print("UPDATED: Custodian Images model")
else:
    conn.execute(
        "INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)",
        (image_model_id, '', 'gpt-image-2-hd', 'Custodian Images', '{}', image_meta, now, now))
    print("CREATED: Custodian Images model")

# ── 4. Fix image_generation config in DB ──
# LiteLLM URL (internal Tailscale)
LITELLM_URL = "http://100.64.0.1:4000/v1"

# Get custodian API key from IMAGES_OPENAI_API_KEY env or openai.api_keys
custodian_key = os.environ.get("IMAGES_OPENAI_API_KEY", "")
if not custodian_key:
    keys_row = conn.execute("SELECT value FROM config WHERE key='openai.api_keys'").fetchone()
    if keys_row:
        keys = json.loads(keys_row[0])
        custodian_key = keys[-1] if keys else ""

if not custodian_key:
    print("WARNING: Could not determine custodian API key!")
    custodian_key = "SKIP"

config_updates = [
    ("image_generation.enable", json.dumps(True)),
    ("image_generation.engine", json.dumps("openai")),
    ("image_generation.model", json.dumps("gpt-image-2-hd")),
    ("image_generation.size", json.dumps("1024x1024")),
    ("image_generation.openai.api_base_url", json.dumps(LITELLM_URL)),
]

if custodian_key != "SKIP":
    config_updates.append(("image_generation.openai.api_key", json.dumps(custodian_key)))

for key, val_json in config_updates:
    existing = conn.execute("SELECT value FROM config WHERE key=?", (key,)).fetchone()
    if existing:
        if existing[0] != val_json:
            conn.execute("UPDATE config SET value=? WHERE key=?", (val_json, key))
            changes.append(f"UPDATED config: {key}")
            print(f"  UPDATED: {key}")
    else:
        conn.execute("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", (key, val_json))
        changes.append(f"ADDED config: {key}")
        print(f"  ADDED: {key}")

# ── 5. Wire gpt-image-2-hd and dashscope-vision to LiteLLM ──
rows = conn.execute(
    "SELECT key, value FROM config WHERE key IN ('openai.api_configs', 'openai.api_base_urls', 'openai.api_keys')"
).fetchall()
configs = {r[0]: json.loads(r[1]) if r[1] else {} for r in rows}

# Ensure LiteLLM URL is in base_urls
urls = configs.get("openai.api_base_urls", [])
if LITELLM_URL not in urls:
    urls.append(LITELLM_URL)
    conn.execute("UPDATE config SET value=? WHERE key=?", (json.dumps(urls), "openai.api_base_urls"))
    # Also add key
    keys = configs.get("openai.api_keys", [])
    keys.append(custodian_key)
    conn.execute("UPDATE config SET value=? WHERE key=?", (json.dumps(keys), "openai.api_keys"))
    changes.append("ADDED LiteLLM connection")
    print("  ADDED: LiteLLM connection")

# Per-model routing
api_cfgs = configs.get("openai.api_configs", {})
for model_name in ["dashscope-vision", "gpt-image-2-hd"]:
    if model_name not in api_cfgs or not api_cfgs[model_name].get("api_base_url"):
        api_cfgs[model_name] = {
            "api_base_url": LITELLM_URL,
            "api_key": custodian_key
        }
        changes.append(f"ROUTED {model_name} -> LiteLLM")
        print(f"  ROUTED: {model_name} -> LiteLLM")

conn.execute("UPDATE config SET value=? WHERE key=?", (json.dumps(api_cfgs), "openai.api_configs"))

conn.commit()
conn.close()

print(f"\n=== DONE: {len(changes)} changes ===")
for c in changes:
    print(f"  - {c}")
PYEOF

# Inject and run
docker cp /tmp/fix_dell_models.py "$WEBUI_CONTAINER":/tmp/
echo ""
echo "Running fix script inside WebUI container..."
OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/fix_dell_models.py 2>&1)
echo "$OUTPUT"

# Cleanup
docker exec "$WEBUI_CONTAINER" rm /tmp/fix_dell_models.py 2>/dev/null || true
rm /tmp/fix_dell_models.py

# Restart WebUI to reload model cache
echo ""
echo "Restarting WebUI to refresh model cache..."
docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1

# Wait for WebUI
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
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
print('--- Models ---')
for r in c.execute(\"SELECT name, base_model_id, json_extract(meta,'$.capabilities') FROM model WHERE name LIKE '%ustodian%' OR name='dashscope-vision' OR name='gpt-image-2-hd'\").fetchall():
    print(f'  {r[0]:25s} base={r[1] or \"NULL\":20s} caps={r[2]}')
print('--- Image config ---')
for k in ['image_generation.enable','image_generation.engine','image_generation.model','image_generation.openai.api_key']:
    r = c.execute('SELECT value FROM config WHERE key=?',(k,)).fetchone()
    v = r[0] if r else 'MISSING'
    if 'key' in k and v and len(v)>20: v = v[:20]+'...'
    print(f'  {k}: {v}')
c.close()
" 2>&1

echo ""
echo "=== DONE ==="
echo "Custodian workspace model: chat + web_search + vision (NO image_generation)"
echo "Custodian Images model: image_generation only (gpt-image-2-hd via LiteLLM)"
echo "API-fetched Hermes model: DELETED (no more duplicate)"
