"""
title: Custodian Video
author: Custodian
description: Creates a short video from your description.
version: 1.0.0
"""

from pydantic import BaseModel
import aiohttp
import asyncio
import base64
from urllib.parse import quote

from open_webui.routers.images import get_image_config


def _first_object(payload):
    """LiteLLM's raw /videos REST endpoints wrap responses in an OpenAI-style
    {"data": [VideoObject]} envelope (the SDK unwraps this; raw HTTP does not).
    Return the inner object so .id / .status resolve correctly."""
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list) and data:
            return data[0]
    return payload if isinstance(payload, dict) else {}


class Pipe:
    class Valves(BaseModel):
        # Provider/model config lives here — never hardcoded in code.
        # MODEL is the LiteLLM model_name (NOT the full provider path). It maps
        # to a model_list entry on the proxy (e.g. "custodian-video" ->
        # gemini/veo-3.1-lite-generate-preview). To change tier (Lite/Fast/Std),
        # change the proxy's litellm_params.model — the customer key stays the same.
        MODEL: str = "custodian-video"
        SIZE: str = "1280x720"
        SECONDS: str = "8"
        # API key + base URL are intentionally NOT valves. They're read from the
        # same image config the native image generator uses (the customer's own
        # virtual key -> LiteLLM), so video spend lands in the SAME budget bucket
        # as chat + images. This is the "one key = one budget" guarantee.

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
            return "Tell me what you'd like me to create, and I'll make a short video of it."

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Creating your video… this usually takes about a minute.", "done": False}}
            )

        # 2. Read the customer's key + LiteLLM URL from the image config (same source
        #    the native image generator uses, so they always stay in sync).
        image_config = await get_image_config()
        base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
        api_key = image_config.IMAGES_OPENAI_API_KEY

        if not base_url or not api_key:
            return "Video isn't configured yet. Please try again shortly."

        # 3. Generate the video through LiteLLM (unified /videos surface).
        video_bytes = None
        try:
            async with aiohttp.ClientSession() as session:
                # 3a. Initiate generation.
                async with session.post(
                    f"{base_url}/videos",
                    headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                    json={
                        "model": self.valves.MODEL,
                        "prompt": prompt,
                        "size": self.valves.SIZE,
                        "seconds": self.valves.SECONDS,
                    },
                    timeout=aiohttp.ClientTimeout(total=60),
                ) as response:
                    if response.status != 200:
                        return "I couldn't create that video. Please try again."
                    job = _first_object(await response.json())

                video_id = job.get("id") or job.get("video_id")
                if not video_id:
                    return "I couldn't create that video. Please try again."

                # 3b. Poll until done (Veo is async — can take 30s–2min).
                for _ in range(24):  # up to ~4 min
                    await asyncio.sleep(10)
                    async with session.get(
                        f"{base_url}/videos/{quote(video_id, safe='')}",
                        headers={"Authorization": f"Bearer {api_key}"},
                        timeout=aiohttp.ClientTimeout(total=30),
                    ) as response:
                        if response.status != 200:
                            continue
                        status = _first_object(await response.json())
                    state = status.get("status")
                    if state == "completed":
                        break
                    if state == "failed":
                        return "Video generation failed. Please try again."
                else:
                    return "Video generation timed out. Please try again."

                # 3c. Download the finished video.
                async with session.get(
                    f"{base_url}/videos/{quote(video_id, safe='')}/content",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=aiohttp.ClientTimeout(total=120),
                ) as response:
                    if response.status != 200:
                        return "I couldn't retrieve that video. Please try again."
                    video_bytes = await response.read()
        except Exception:
            return "I couldn't create that video. Please try again."

        if not video_bytes:
            return "I couldn't create that video. Please try again."

        # 4. Return the video. LiteLLM's download endpoint requires auth, so the
        #    customer can't fetch it directly — deliver the bytes as a data URI.
        b64 = base64.b64encode(video_bytes).decode("utf-8")
        url = f"data:video/mp4;base64,{b64}"

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Video created", "done": True}}
            )
            await __event_emitter__(
                {"type": "files", "data": {"files": [{"type": "video", "url": url}]}}
            )

        return ""
