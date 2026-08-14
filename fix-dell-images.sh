#!/bin/bash
# fix-dell-images.sh
# Run ON THE DELL (192.168.50.250) as root.
# Fixes the three image/UX issues:
#   1. IMAGES  — replaces the broken "Custodian Images" chat model (which sent
#                prompts to /v1/chat/completions and 500'd) with a native Pipe
#                function that generates images only (no DeepSeek text reply).
#   2. DESCRIPTIONS — strips tech jargon (DALL-E / LiteLLM / Hermes / Budget Proxy)
#                from the "Custodian" and "Custodian Images" descriptions.
#   3. AUTO-SELECT — sets ui.default_models so "Custodian" is the default model.

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

echo "=== Fix Dell: Custodian Images pipe + descriptions + auto-select ==="

# ── 1. Write the Pipe function code into the container ──
cat > /tmp/custodian_images_pipe.py << 'PIPEEOF'
"""
title: Custodian Images
author: Custodian
description: Creates an image from your description.
version: 1.0.0
"""

from pydantic import BaseModel
import aiohttp

from open_webui.routers.images import (
    get_image_config,
    get_image_data,
    upload_image,
)
from open_webui.models.users import UserModel


class Pipe:
    class Valves(BaseModel):
        pass

    def __init__(self):
        self.valves = self.Valves()

    async def pipe(
        self,
        body,
        __event_emitter__=None,
        __user__=None,
        __request__=None,
        __metadata__=None,
    ):
        # 1. Pull the user's latest prompt out of the message list.
        prompt = ""
        for message in reversed(body.get("messages", [])):
            if message.get("role") != "user":
                continue
            content = message.get("content", "")
            if isinstance(content, str):
                prompt = content
            elif isinstance(content, list):
                parts = []
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        parts.append(part.get("text", ""))
                prompt = "".join(parts)
            break
        prompt = prompt.strip()
        if not prompt:
            return "Tell me what you'd like me to create, and I'll make an image of it."

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Creating your image...", "done": False}}
            )

        # 2. Read the image configuration — same source the native image
        #    generator uses, so key/model/URL always stay in sync.
        image_config = await get_image_config()

        # 3. Call the image engine.
        payload = {
            "model": image_config.IMAGE_GENERATION_MODEL,
            "prompt": prompt,
            "n": 1,
        }
        if getattr(image_config, "IMAGE_SIZE", None):
            payload["size"] = image_config.IMAGE_SIZE
        payload["response_format"] = "b64_json"

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{image_config.IMAGES_OPENAI_API_BASE_URL}/images/generations",
                    headers={
                        "Authorization": f"Bearer {image_config.IMAGES_OPENAI_API_KEY}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=180),
                ) as response:
                    if response.status != 200:
                        return "I couldn't create that image. Please try again."
                    data = await response.json()
        except Exception:
            return "I couldn't create that image. Please try again."

        # 4. Build the images list. Prefer uploading into OpenWebUI storage so
        #    the 3-day cleanup applies; fall back to an inline data URI.
        user_obj = None
        try:
            if isinstance(__user__, dict) and __user__.get("id"):
                user_obj = UserModel(**__user__)
        except Exception:
            user_obj = None

        metadata = __metadata__ if isinstance(__metadata__, dict) else {}

        images = []
        for item in data.get("data", []):
            raw = item.get("url") or item.get("b64_json") or ""
            if not raw:
                continue
            url = None
            if user_obj is not None and __request__ is not None:
                try:
                    image_data, content_type = await get_image_data(raw)
                    if image_data is not None and content_type is not None:
                        _, url = await upload_image(
                            __request__, image_data, content_type, metadata, user_obj
                        )
                except Exception:
                    url = None
            if not url:
                if raw.startswith(("http://", "https://")):
                    url = raw
                else:
                    url = f"data:image/png;base64,{raw}"
            images.append({"type": "image", "url": url})

        if not images:
            return "I couldn't create that image. Please try again."

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Image created", "done": True}}
            )
            await __event_emitter__({"type": "files", "data": {"files": images}})

        return ""
PIPEEOF

# ── 2. Write the DB-fix Python script ──
cat > /tmp/fix_images.py << 'PYEOF'
import sqlite3, json, time, uuid

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())
changes = []

# ── 1. DELETE the broken "Custodian Images" chat model (base_model_id=gpt-image-2-hd) ──
broken = conn.execute(
    "SELECT id FROM model WHERE name='Custodian Images' AND base_model_id='gpt-image-2-hd'"
).fetchall()
for row in broken:
    conn.execute("DELETE FROM model WHERE id=?", (row[0],))
    changes.append(f"DELETED broken 'Custodian Images' chat model (id={row[0][:8]}...)")
    print(f"DELETED broken 'Custodian Images' chat model id={row[0][:8]}...")

if not broken:
    print("OK: No broken 'Custodian Images' model found (already clean)")

# ── 2. UPSERT the Custodian Images Pipe function ──
pipe_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-images-pipe'))
pipe_meta = json.dumps({
    "description": "Turn your description into an image. Images are kept for 3 days, then removed automatically.",
    "manifest": {"name": "Custodian Images", "version": "1.0.0"},
})

with open('/tmp/custodian_images_pipe.py', 'r') as f:
    pipe_content = f.read()

existing_pipe = conn.execute("SELECT id FROM function WHERE id=?", (pipe_id,)).fetchone()
if existing_pipe:
    conn.execute(
        "UPDATE function SET name=?, type=?, content=?, meta=?, is_active=?, is_global=?, updated_at=? WHERE id=?",
        ('Custodian Images', 'pipe', pipe_content, pipe_meta, True, True, now, pipe_id),
    )
    changes.append("UPDATED Custodian Images pipe function")
    print("UPDATED: Custodian Images pipe function")
else:
    conn.execute(
        "INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (pipe_id, None, 'Custodian Images', 'pipe', pipe_content, pipe_meta, '{}', True, True, now, now),
    )
    changes.append("CREATED Custodian Images pipe function")
    print("CREATED: Custodian Images pipe function")

# ── 3. De-jargon the "Custodian" model description ──
custodian_meta = json.dumps({
    "capabilities": {"web_search": True, "vision": True},
    "description": "Your AI assistant for questions, writing, and everyday help. To create images, switch to 'Custodian Images'.",
})
custodian = conn.execute(
    "SELECT id FROM model WHERE name='Custodian' AND base_model_id IS NOT NULL"
).fetchone()
if custodian:
    conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?", (custodian_meta, now, custodian[0]))
    changes.append("UPDATED 'Custodian' description (de-jargoned)")
    print("UPDATED: 'Custodian' description")
    custodian_id = custodian[0]
else:
    custodian_id = None
    print("WARNING: 'Custodian' model not found — skipping description + auto-select")

# ── 4. Auto-select "Custodian" (ui.default_models) ──
if custodian_id:
    default_val = json.dumps(custodian_id)  # stored as a JSON string
    conn.execute("INSERT INTO config (key, value) VALUES ('ui.default_models', ?) "
                 "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (default_val,))
    changes.append("SET ui.default_models -> Custodian (auto-select)")
    print(f"SET: ui.default_models -> {custodian_id}")

conn.commit()
conn.close()

print(f"\n=== DONE: {len(changes)} changes ===")
for c in changes:
    print(f"  - {c}")
PYEOF

# ── 3. Copy both files into the container and run ──
docker cp /tmp/custodian_images_pipe.py "$WEBUI_CONTAINER":/tmp/
docker cp /tmp/fix_images.py "$WEBUI_CONTAINER":/tmp/
echo ""
echo "Running fix script inside WebUI container..."
OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/fix_images.py 2>&1)
echo "$OUTPUT"

# ── 4. Cleanup ──
docker exec "$WEBUI_CONTAINER" rm -f /tmp/custodian_images_pipe.py /tmp/fix_images.py 2>/dev/null || true
rm -f /tmp/custodian_images_pipe.py /tmp/fix_images.py

# ── 5. Restart WebUI to refresh the model cache (pipe models are cached) ──
echo ""
echo "Restarting WebUI to refresh model cache..."
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

# ── 6. Verify ──
echo ""
echo "=== VERIFY ==="
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
print('--- Models ---')
for r in c.execute(\"SELECT name, base_model_id FROM model WHERE name LIKE '%ustodian%'\").fetchall():
    print(f'  {r[0]:20s} base={r[1] or \"NULL\"}')
print('--- Functions ---')
for r in c.execute(\"SELECT name, type, is_active, is_global FROM function WHERE name LIKE '%ustodian%'\").fetchall():
    print(f'  {r[0]:20s} type={r[1]:6s} active={r[2]} global={r[3]}')
print('--- ui.default_models ---')
r = c.execute(\"SELECT value FROM config WHERE key='ui.default_models'\").fetchone()
print(' ', r[0] if r else 'MISSING')
c.close()
" 2>&1

echo ""
echo "=== DONE ==="
echo "'Custodian Images' is now a Pipe function (image-only, no text reply)."
echo "'Custodian' is the default model with a clean, non-technical description."
