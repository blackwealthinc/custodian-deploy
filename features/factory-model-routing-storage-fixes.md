# Factory Fixes + New Features — Model Routing, Storage Cap, Deletion Warning

**Date:** 2026-08-13
**Status:** Audit complete + solutions designed. **No changes applied yet** (awaiting approval).
**Trigger:** "Model not found" when using images (Custodian Images) — expanded into a full line-by-line audit of the Dell (192.168.50.250) and VM205 (192.168.50.205).

---

## What We Found — 8 Bugs

| Local Bug | GitHub Issue | Severity | Summary |
|-----------|--------------|----------|---------|
| #95 | #83 | 🔴 | `OPENAI_API_BASE_URL` (singular) overrides the DB's 2-URL list → LiteLLM never fetched → "Model not found" (images) |
| #96 | #84 | 🔴 | Cleanup timer points at `/home/custodian`, real images live in `/data` → 3-day deletion silently does nothing |
| #97 | #85 | 🔴 | `API_SERVER_MODEL_NAME=hermes-backend` rename left "Custodian" model with dangling `base_model_id='Custodian'` → chat broken |
| #98 | #86 | 🔴 | Two LiteLLM keys (sk-6tc vs sk-zLD) — violates one-key-per-customer |
| #99 | #87 | 🟡 | `RAG_FILE_MAX_SIZE=10000` is per-file (10 GB × 10 files ≈ 100 GB), no total cap |
| #100 | #88 | 🟡 | Local scripts stale vs GitHub `main` |
| #101 | #89 | 🔴 | Step 5c Deep Research filter references `source`/`meta` before definition (latent NameError) |
| #102 | #90 | 🟡 | `openai.api_configs` keyed by model-name not connection-index (dead config) + dashscope-vision self-reference |

### Root Cause (The Big One — #95)

`config.py` (OpenWebUI) maps `openai.api_base_urls` → env `OPENAI_API_BASE_URLS` (plural), which **falls back to the singular `OPENAI_API_BASE_URL`**. The compose sets the *singular* var for the Hermes connection, and `ENABLE_PERSISTENT_CONFIG=false` makes env authoritative over DB. Result: runtime sees **1 URL** (Hermes only), LiteLLM is never fetched, and the 4 LiteLLM models (`gpt-image-2-hd`, `deepseek-chat`, `deepseek-v4-pro`, `deepseek-v4-flash`) never load into `app.state.MODELS`.

**Evidence:** `/api/models` returns 5 models (missing 4 LiteLLM); `get_openai_runtime_config()` returns 1 URL; log `Error processing chat metadata: Model not found` at `chat_completion:1541`.

**Two independent breakages:** images (base `gpt-image-2-hd` missing → Bug #95) AND chat (base `Custodian` missing after rename → Bug #97).

---

## Solutions

### Fix 1 — Compose: restore LiteLLM connection (Bugs #95 + #98)

`docker-compose.custodian-factory.yml`, `openwebui` service env:

```yaml
      # OpenAI connections — Hermes (chat) + LiteLLM (vision/images), semicolon-separated
      - OPENAI_API_BASE_URLS=http://hermes:8642/v1;http://100.64.0.1:4000/v1
      - OPENAI_API_KEYS=${API_SERVER_KEY};${CUSTOMER_API_KEY}
      # Upload limits — 100 MB/file, 10 files/upload; 10 GB TOTAL via cleanup timer
      - RAG_FILE_MAX_SIZE=100
      - RAG_FILE_MAX_COUNT=10
```

- Connection[0] (Hermes) unchanged. Connection[1] (LiteLLM) reuses `CUSTOMER_API_KEY` (= `sk-zLD`, the key already powering chat + images) → **auto-unifies the two keys** (fixes #98).
- `RAG_FILE_MAX_SIZE=100` (MB) replaces the incorrect `10000` (10 GB per-file).

### Fix 2 — Step 5d: point "Custodian" at the real Hermes model (Bug #97)

`setup-custodian-factory.sh`, Step 5d:

```python
existing = conn.execute("SELECT id FROM model WHERE name='Custodian'").fetchone()
if existing:
    conn.execute('UPDATE model SET base_model_id=?, meta=?, updated_at=? WHERE id=?',
        ('hermes-backend', meta, now, existing[0]))
    was_update = True
else:
    model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-model'))
    conn.execute('''INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)''',
        (model_id, '', 'hermes-backend', 'Custodian', json.dumps({}), meta, now, now))
    was_update = False
```

Two changes: `INSERT` base → `'hermes-backend'`; `UPDATE` now also sets `base_model_id` (the old UPSERT only touched `meta`, so it never self-healed).

### Fix 3 — Cleanup: correct path + 3-day + 30-day + 10 GB total (Bugs #96 + #99)

Replace Step 5f with a standalone script + service:

```bash
cat > /usr/local/bin/custodian-cleanup.sh << 'SCRIPTEOF'
#!/bin/bash
set -uo pipefail

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

cat > /etc/systemd/system/custodian-cleanup.service << 'UNITEOF'
[Unit]
Description=Custodian — cleanup old images/uploads + enforce 10 GB cap
[Service]
Type=oneshot
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

systemctl daemon-reload && systemctl enable --now custodian-cleanup.timer
```

**Note:** the 10 GB total is a *storage-accounting* problem, which OpenWebUI has no native setting for (only per-file size + per-upload count). This is the standard retention approach — same as ChatGPT/Claude.

### Fix 4 — "Deleted in 3 days" warning (new feature)

Two layers (no source fork):

**(a) Description** — the native popup when a model is clicked. Step 5d `image_meta`:

```python
image_meta = json.dumps({
    "capabilities": {"image_generation": True},
    "description": "⚠️ DALL-E HD image generation via LiteLLM. Images are auto-deleted after 3 days — save important images locally."
})
```

**(b) Status filter** — in-chat warning on use (same pattern as the Deep Research filter). New Step 5g:

```python
cat > /tmp/inject_image_warning.py << 'PYEOF'
import sqlite3, json, uuid, time
conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())

source = '''"""
title: Image Deletion Warning
author: Custodian
description: Warns that generated images are auto-deleted after 3 days.
version: 1.0.0
"""
from pydantic import BaseModel, Field
from typing import Optional

class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0)

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __user__: Optional[dict] = None, __event_emitter__=None) -> dict:
        model = body.get("model", "")
        if model in {"374e596f-9137-584f-a75a-b770059dee2e", "gpt-image-2-hd"} and __event_emitter__:
            await __event_emitter__({
                "type": "status",
                "data": {"description": "Images are auto-deleted after 3 days — save important images locally.", "done": True}
            })
        return body
'''

meta = json.dumps({"description": "Warns that generated images are deleted after 3 days.",
                   "manifest": {"name": "Image Deletion Warning", "version": "1.0.0"}})
valves = json.dumps({})
func_id = str(uuid.uuid4())

existing = conn.execute("SELECT id FROM function WHERE name='Image Deletion Warning' AND type='filter'").fetchone()
if existing:
    conn.execute("UPDATE function SET content=?, meta=?, updated_at=? WHERE id=?", (source, meta, now, existing[0]))
else:
    conn.execute("INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, updated_at, created_at) VALUES (?, NULL, ?, 'filter', ?, ?, ?, TRUE, TRUE, ?, ?)",
        (func_id, 'Image Deletion Warning', source, meta, valves, now, now))
conn.commit(); conn.close()
print("OK")
PYEOF
docker cp /tmp/inject_image_warning.py "$WEBUI_CONTAINER":/tmp/
docker exec "$WEBUI_CONTAINER" python3 /tmp/inject_image_warning.py
docker exec "$WEBUI_CONTAINER" rm /tmp/inject_image_warning.py
rm /tmp/inject_image_warning.py
```

**Honest note:** OpenWebUI has no native "modal popup on model select." The description card (a) is the native popup; the filter (b) puts the warning in the chat. A true modal needs a frontend fork — not recommended.

### Fix 5 — Step 5e: drop misleading `api_configs` writes (Bug #102)

Remove the two blocks writing `api_cfgs["dashscope-vision"]` / `api_cfgs["gpt-image-2-hd"]` (lines 602-625). Routing already works via `base_model_id`; those writes are dead config.

### Fix 6 — Step 5c: fix the latent NameError (Bug #101)

Move the `source` and `meta` definitions **above** the `existing` check in `inject_deep_research.py` (same fix as Bug #87 in Step 5d).

### Fix 7 — Re-sync local files (Bug #100)

Treat GitHub `main` as the single source of truth; re-pull the local clone.

---

## One-Time Dell Commands (only these can't self-heal via curl)

```bash
# 1) Re-point the existing "Custodian" row (Bug #97)
echo "UPDATE model SET base_model_id='hermes-backend' WHERE name='Custodian' AND base_model_id='Custodian';" | \
  sudo docker exec -i admin-webui sqlite3 /app/backend/data/webui.db

# 2) Recreate the WebUI with the new compose (Fix 1)
cd /data && sudo docker compose -p admin -f docker-compose.custodian-factory.yml up -d --force-recreate
```

---

## Why It's Safe & Scalable

- **Safe:** every change is additive or a one-field re-point. Only the cleanup timer deletes data, and only old/over-cap files (age + size filters). No secrets touched — Fix 1 reuses the existing `sk-zLD` key.
- **Scalable:** parameterized by `CUSTOMER_ID`; each container runs its own `custodian-cleanup.timer`, so the 10 GB cap scales per-customer with zero extra work.
- **Restart-safe:** `ENABLE_PERSISTENT_CONFIG=false` makes compose the source of truth.
- **No source fork:** everything is env vars, DB rows, or OpenWebUI's Functions system — except the host-side cleanup script (which is required because a *total* cap has no native OpenWebUI setting).

---

## Verification (before declaring "done")

1. `curl ... | sudo -E bash` the factory script on a fresh box → both models resolve.
2. `/api/models` shows `gpt-image-2-hd` AND `hermes-backend`.
3. "Custodian" (chat) returns a real DeepSeek reply.
4. "Custodian Images" generates an image (no "Model not found").
5. Selecting "Custodian Images" shows the warning (description + status).
6. `systemctl status custodian-cleanup.timer` = active; `du -sh /data/webui-data/uploads` stays ≤ 10 GB.

---

## Files Changed (planned)

| File | Change |
|------|--------|
| `docker-compose.custodian-factory.yml` | plural `OPENAI_API_BASE_URLS`/`OPENAI_API_KEYS`; `RAG_FILE_MAX_SIZE=100` |
| `setup-custodian-factory.sh` | Step 5d base fix, Step 5e cleanup, Step 5c reorder, new Step 5f (cleanup script) + Step 5g (warning filter) |
| `/usr/local/bin/custodian-cleanup.sh` + systemd units | new (10 GB cap + retention) |
| Dell DB (one-time) | `UPDATE model SET base_model_id='hermes-backend'` |
| Local clone | re-sync from GitHub `main` |
