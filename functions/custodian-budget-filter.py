"""
title: Custodian Budget Bar
author: Custodian
description: Automatically shows your live spend after every response.
version: 1.0.0
"""

from pydantic import BaseModel, Field
from typing import Optional
import aiohttp

from open_webui.routers.images import get_image_config


class Filter:
    class Valves(BaseModel):
        priority: int = Field(
            default=0,
            description="Runs last so the balance is appended after other filters.",
        )

    def __init__(self):
        self.valves = self.Valves()

    async def _fetch_budget(self):
        # Read the customer's key + LiteLLM URL from the image config (same source
        # as chat/images/video — one key = one budget). Reuses the exact logic of
        # the "Custodian Budget" pipe.
        image_config = await get_image_config()
        base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
        api_key = image_config.IMAGES_OPENAI_API_KEY

        if not base_url or not api_key:
            return None

        # LiteLLM admin endpoints live at the proxy ROOT, not under /v1.
        root = base_url[:-3] if base_url.endswith("/v1") else base_url

        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{root}/key/info",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=aiohttp.ClientTimeout(total=30),
                ) as response:
                    if response.status != 200:
                        return None
                    data = await response.json()
        except Exception:
            return None

        info = data.get("info", data)
        spend = info.get("spend", 0.0) or 0.0
        max_budget = info.get("max_budget")

        try:
            spend = float(spend)
        except (TypeError, ValueError):
            spend = 0.0

        if max_budget:
            try:
                remaining = float(max_budget) - spend
                return f"\n\n> 💳 **${spend:.2f}** used this month · **${remaining:.2f}** remaining"
            except (TypeError, ValueError):
                pass

        return f"\n\n> 💳 **${spend:.2f}** used this month"

    async def outlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __event_emitter__=None,
    ) -> dict:
        # Append the live balance line to the assistant's reply. Fails closed:
        # if anything goes wrong (LiteLLM down, malformed body, etc.) the message
        # passes through unchanged.
        try:
            messages = body.get("messages", [])
            if not messages:
                return body

            last = messages[-1]
            if last.get("role") != "assistant":
                return body

            line = await self._fetch_budget()
            if not line:
                return body

            content = last.get("content")
            if isinstance(content, str):
                last["content"] = content + line
            else:
                last["content"] = line.strip()

            return body
        except Exception:
            return body
