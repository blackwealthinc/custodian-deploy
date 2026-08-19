"""
title: Custodian Budget
author: Custodian
description: Shows how much you've used this month.
version: 1.0.0
"""

from pydantic import BaseModel
import aiohttp

from open_webui.routers.images import get_image_config


class Pipe:
    class Valves(BaseModel):
        # Price placeholder — intentionally empty for now. When pricing is decided
        # (after Kill Bill), this becomes the plan price so the counter can show
        # "$X of $Y". For now it reports raw spend only.
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
        # 1. Read the customer's key + LiteLLM URL from the image config (same
        #    source as images/video, so we query the SAME key that chat/images/
        #    video all draw from — one budget, one number).
        image_config = await get_image_config()
        base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
        api_key = image_config.IMAGES_OPENAI_API_KEY

        if not base_url or not api_key:
            return "Budget info isn't available yet. Please try again shortly."

        # LiteLLM admin endpoints live at the proxy ROOT, not under /v1.
        root = base_url[:-3] if base_url.endswith("/v1") else base_url

        # 2. Ask LiteLLM for this key's own spend. The customer key is authorized
        #    to read its own /key/info (verified) — no separate viewer key needed.
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{root}/key/info",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=aiohttp.ClientTimeout(total=30),
                ) as response:
                    if response.status != 200:
                        return "I couldn't read your usage right now. Please try again."
                    data = await response.json()
        except Exception:
            return "I couldn't read your usage right now. Please try again."

        info = data.get("info", data)
        spend = info.get("spend", 0.0) or 0.0
        max_budget = info.get("max_budget")

        # 3. Raw spend only for now (no pricing). When a plan price exists, this
        #    becomes "$X of $Y used".
        try:
            spend = float(spend)
        except (TypeError, ValueError):
            spend = 0.0

        if max_budget:
            try:
                remaining = float(max_budget) - spend
                return (
                    f"You've used **${spend:.2f}** so far, with **${remaining:.2f}** remaining."
                )
            except (TypeError, ValueError):
                pass

        return f"You've used **${spend:.2f}** so far."
