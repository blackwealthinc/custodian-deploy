# Image Generation — Complete Implementation Plan

**Date:** 2026-08-08
**Status:** Audit & Plan (no changes made yet)

---

## Current State (Discovered During Audit)

### VM205 — 3 Virtual Keys

```
┌────────────────┬───────────┬──────────────────────────────────────┬─────────┬────────────┐
│ Key Alias      │ Token     │ Models                               │ Spend   │ Budget     │
├────────────────┼───────────┼──────────────────────────────────────┼─────────┼────────────┤
│ (no alias)     │ sk-6tc... │ dashscope-vision, deepseek-chat,     │ $0.014  │ $50        │
│                │           │ deepseek-v4-pro, deepseek-v4-flash,  │         │            │
│                │           │ gpt-image-2-hd                       │         │            │
├────────────────┼───────────┼──────────────────────────────────────┼─────────┼────────────┤
│ custodian      │ sk-zLD... │ deepseek-v4-pro, gpt-image-2-hd      │ $0.18   │ $100/mo    │
├────────────────┼───────────┼──────────────────────────────────────┼─────────┼────────────┤
│ admin          │ N/A       │ deepseek-v4-pro, deepseek-v4-flash   │ $0.175  │ $100       │
└────────────────┴───────────┴──────────────────────────────────────┴─────────┴────────────┘
```

### Dell — Which Key Powers What

| Feature    | Uses Key        | How Discovered                                      |
|------------|-----------------|-----------------------------------------------------|
| Chat       | custodian (sk-zLD...) | Hermes `model.api_key` → `api_keys[0]`         |
| Vision     | custodian (sk-zLD...) | `api_configs["dashscope-vision"]`              |
| Images     | no-alias (sk-6tc...)  | `image_generation.openai.api_key` DB config     |

**Problem:** Budget split across TWO pools. Customer can't see one number.

### Dell — Active Models

```
Custodian          → capabilities: web_search, vision, image_generation
dashscope-vision   → capabilities: vision
gpt-image-2-hd     → capabilities: (none set — used as raw API model)
deepseek-v4-pro    → (API-fetched, no workspace entry)
deepseek-chat      → (API-fetched, no workspace entry)
deepseek-v4-flash  → (API-fetched, no workspace entry)
```

### Bug Found in Factory Curl

**Location:** `setup-custodian-factory.sh`, Step 5e, lines 570-574

```python
# Reads from INSIDE the WebUI container:
result = subprocess.run(["cat", "/opt/data/config.yaml"], ...)
hermes_cfg = yaml.safe_load(result.stdout)
liteLLM_key = hermes_cfg["model"]["api_key"]
```

**Problem:** `/opt/data/config.yaml` does NOT exist in the WebUI container. The WebUI container only mounts `./webui-data:/app/backend/data`. The path `/opt/data` is the Hermes container's volume. This code crashes, and the `image_generation.openai.api_key` gets set to whatever was already in `api_keys[1]` — which happened to be the no-alias key.

---

## Three Tasks

### Task 1: Fix the Curl — One Virtual Key Per Customer

**setup-custodian-factory.sh, line 39 — CHANGE:**

```bash
# BEFORE:
"models": ["deepseek-v4-pro", "gpt-image-2-hd"]

# AFTER:
"models": ["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-chat", "dashscope-vision", "gpt-image-2-hd"]
```

**setup-custodian-factory.sh, lines 568-574 — FIX DEAD PATH:**

```python
# BEFORE (reads from dead path in WebUI container):
result = subprocess.run(["cat", "/opt/data/config.yaml"],
    capture_output=True, text=True)

# AFTER (reads from Hermes container via docker exec):
import subprocess as sp
customer_id = "$CUSTOMER_ID"  # passed via heredoc template
try:
    result = sp.run(["docker", "exec", f"{customer_id}-hermes", "cat", "/opt/data/config.yaml"],
        capture_output=True, text=True, timeout=5)
    hermes_cfg = yaml.safe_load(result.stdout)
    liteLLM_key = hermes_cfg["model"]["api_key"]
except Exception:
    # Fallback: use CUSTOMER_API_KEY env var (already the same key)
    import os
    liteLLM_key = os.environ.get("CUSTOMER_API_KEY", keys[-1] if keys else "")
```

**Why this works:** The Hermes container IS running at this point (Step 5d already configured it). The `docker exec` reads from the running container. The `CUSTOMER_API_KEY` env var fallback ensures the script never crashes — it's the same key Hermes uses.

---

### Task 2: Create "Custodian Images" Model

**New step in factory script (after Step 5d — Custodian model creation):**

```python
# ── Create "Custodian Images" model ──
model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-images-model'))

meta = json.dumps({
    "capabilities": {
        "image_generation": True
    },
    "description": "DALL-E HD image generation via LiteLLM. Images auto-deleted after 3 days. Save important images locally."
})

existing = conn.execute("SELECT id FROM model WHERE name='Custodian Images'").fetchone()
if existing:
    conn.execute('UPDATE model SET meta=?, updated_at=? WHERE id=?',
        (meta, now, existing[0]))
else:
    conn.execute(
        "INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)",
        (model_id, '', 'gpt-image-2-hd', 'Custodian Images', json.dumps({}), meta, now, now)
    )
```

**Also update Custodian model — REMOVE image_generation:**

```python
# In the existing Custodian model creation section (line 491-498):
meta = json.dumps({
    "capabilities": {
        "web_search": True,
        "vision": True
        # image_generation: True  ← REMOVED
    },
    "description": "Custodian AI — Hermes + DeepSeek via Budget Proxy. For images, switch to 'Custodian Images' model."
})
```

**Dell live fix (what you run):**
```bash
docker exec admin-webui python3 << 'PYEOF'
import sqlite3, json, uuid, time

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())

# 1. Create Custodian Images model
model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-images-model'))
meta = json.dumps({
    "capabilities": {"image_generation": True},
    "description": "DALL-E HD image generation via LiteLLM. Images auto-deleted after 3 days. Save important images locally."
})

existing = conn.execute("SELECT id FROM model WHERE name='Custodian Images'").fetchone()
if existing:
    conn.execute('UPDATE model SET meta=?, updated_at=? WHERE id=?', (meta, now, existing[0]))
    print("UPDATED Custodian Images")
else:
    conn.execute(
        "INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)",
        (model_id, '', 'gpt-image-2-hd', 'Custodian Images', json.dumps({}), meta, now, now)
    )
    print("CREATED Custodian Images")

# 2. Remove image_generation from Custodian model
custodian_meta = json.loads(conn.execute(
    "SELECT meta FROM model WHERE name='Custodian' AND base_model_id='Custodian'"
).fetchone()[0])
if 'image_generation' in custodian_meta.get('capabilities', {}):
    del custodian_meta['capabilities']['image_generation']
custodian_meta['description'] = "Custodian AI — Hermes + DeepSeek via Budget Proxy. For images, switch to 'Custodian Images' model."
conn.execute("UPDATE model SET meta=?, updated_at=? WHERE name='Custodian' AND base_model_id='Custodian'",
    (json.dumps(custodian_meta), now))
print("UPDATED Custodian (removed image_generation)")

conn.commit()
conn.close()
PYEOF
```

---

### Task 3: Housekeeping — Auto-Delete + Upload Limits

**docker-compose.custodian-factory.yml — ADD to openwebui environment:**

```yaml
- RAG_FILE_MAX_SIZE=50         # Max upload file size in MB
- RAG_FILE_MAX_COUNT=10        # Max files per upload batch
```

**Systemd timer (added to factory script):**

```bash
# Create cleanup service
cat > /etc/systemd/system/custodian-cleanup.service << 'UNITEOF'
[Unit]
Description=Delete old generated images and uploaded files

[Service]
Type=oneshot
# Generated images: 3 days
ExecStart=/usr/bin/find /home/custodian/webui-data/uploads -name '*_generated-image.*' -mtime +3 -delete
# Uploaded screenshots/files: 30 days
ExecStart=/usr/bin/find /home/custodian/webui-data/uploads ! -name '*_generated-image.*' -mtime +30 -delete
UNITEOF

# Create cleanup timer
cat > /etc/systemd/system/custodian-cleanup.timer << 'UNITEOF'
[Unit]
Description=Daily cleanup of old images and uploads

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
systemctl enable --now custodian-cleanup.timer
```

**Dell live fix:**
```bash
# Create and start the timer (same as above)
sudo bash -c 'cat > /etc/systemd/system/custodian-cleanup.service << UNITEOF
[Unit]
Description=Delete old generated images and uploaded files

[Service]
Type=oneshot
ExecStart=/usr/bin/find /home/custodian/webui-data/uploads -name "*_generated-image.*" -mtime +3 -delete
ExecStart=/usr/bin/find /home/custodian/webui-data/uploads ! -name "*_generated-image.*" -mtime +30 -delete
UNITEOF'

sudo bash -c 'cat > /etc/systemd/system/custodian-cleanup.timer << UNITEOF
[Unit]
Description=Daily cleanup of old images and uploads

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF'

sudo systemctl daemon-reload
sudo systemctl enable --now custodian-cleanup.timer
```

---

## Safety & Strongman Arguments

### Why This Won't Break Anything

| Change | What It Touches | What It Doesn't Touch |
|--------|----------------|----------------------|
| Virtual key models list | Only the `models` array in the LiteLLM key generation API call | Hermes config, OpenWebUI DB, Dell compose, budget enforcement |
| Dead path fix | Only the Python injection script in Step 5e | Key creation, model routing, existing api_configs |
| Custodian Images model | One new row in the `model` table | Existing Custodian model (just removes one capability flag) |
| Cleanup timer | Files in `uploads/` older than 3 or 30 days | Anything in cache/, vector_db/, webui.db |
| Upload limits | Requests exceeding 50MB or 10 files are rejected | All existing requests under limits |

### Why It's Scalable

- **One key per customer**: Budget tracking is per-key. One key = one number to show the customer.
- **Model pattern reusable**: Same INSERT pattern works for video model later. Just change `base_model_id` and capabilities.
- **Cleanup timer is per-machine**: Each Dell has its own timer. No shared state. Works identically for 1 customer or 50.
- **Upload limits in compose**: Set once, applies to all customers on that machine. Env var, not DB — harder to override accidentally.

### What Happens If Something Goes Wrong

| Failure Scenario | What Happens | Recovery |
|-----------------|--------------|----------|
| Key creation fails | Script exits before deploying | No partial state. Fix key, re-run. |
| Dead path fix fails | Falls back to `CUSTOMER_API_KEY` env var | Same key either way. No difference. |
| Custodian Images model creation crashes | Non-fatal — factory script continues | Model can be created manually. No impact on existing functionality. |
| Cleanup timer deletes wrong files | It can't — `find` patterns are specific to `_generated-image.*` and `! -name '*_generated-image.*'` | Even if `find` matched wrong files, old uploads are the only files in `uploads/` |
| Cleanup timer fails to start | Timer doesn't run. Images accumulate. | System just keeps old files — no data loss, just disk growth. Fix timer, it catches up on next run (`Persistent=true`). |

### Verification Steps (Before Declaring "Done")

1. **Key consolidation**: Run `curl localhost:4000/key/info -H "Authorization: Bearer <master>"` and verify the customer key has all 5 models
2. **Model creation**: Check WebUI model dropdown — "Custodian Images" appears with image toggle visible
3. **Custodian model**: Check WebUI model dropdown — "Custodian" no longer shows image toggle
4. **Image generation**: Toggle ON in Custodian Images, type prompt, verify image appears with NO confused text
5. **Cleanup timer**: `sudo systemctl status custodian-cleanup.timer` shows active
6. **Upload limits**: Try uploading a file > 50MB — should be rejected

---

## Files Changed

| File | What Changed |
|------|-------------|
| `setup-budget-proxy.sh` | Nothing (already correct — admin key has all 5 models) |
| `setup-custodian-factory.sh` | Line 39 (models list), lines 570-574 (dead path fix), new model creation block, model description update |
| `docker-compose.custodian-factory.yml` | Add `RAG_FILE_MAX_SIZE` and `RAG_FILE_MAX_COUNT` env vars |
| Dell DB (live fix) | Create Custodian Images model, remove image_generation from Custodian |
| VM205 (no changes needed) | Key already has gpt-image-2-hd. Consolidation happens on fresh deploy. |
| `/etc/systemd/system/` (Dell + factory) | Two new unit files for cleanup timer |
