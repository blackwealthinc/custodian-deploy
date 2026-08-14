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
