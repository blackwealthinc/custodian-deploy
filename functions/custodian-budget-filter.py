"""
title: Custodian Budget Bar
author: Custodian
description: Automatically shows your live spend after every response.
version: 1.5.0
"""

from pydantic import BaseModel, Field
from typing import Optional
import time

import aiohttp

from open_webui.routers.images import get_image_config

# Module-level TTL cache: api_key -> (expiry_monotonic, formatted_line).
# OpenWebUI caches the filter module (content-keyed, app-level) and runs a single
# uvicorn worker, so this dict persists across requests and dedupes /key/info
# calls across every user in the container (they all share one customer key).
_BUDGET_CACHE = {}
_BUDGET_CACHE_TTL = 30.0  # seconds


class Filter:
    class Valves(BaseModel):
        priority: int = Field(
            default=100,
            description="Runs last so the balance is appended after other filters.",
        )

    def __init__(self):
        self.valves = self.Valves()

    async def _fetch_budget(self):
        # Read the customer's key + LiteLLM URL from the image config (same source
        # as chat/images/video — one key = one budget).
        image_config = await get_image_config()
        base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
        api_key = image_config.IMAGES_OPENAI_API_KEY

        if not base_url or not api_key:
            return None

        # Serve a recent balance from the cache so we don't hit LiteLLM on every
        # message (Bug #135). A miss just falls through to a fresh fetch.
        now = time.monotonic()
        cached = _BUDGET_CACHE.get(api_key)
        if cached and cached[0] > now:
            return cached[1]

        # LiteLLM admin endpoints live at the proxy ROOT, not under /v1.
        root = base_url[:-3] if base_url.endswith("/v1") else base_url

        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{root}/key/info",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=aiohttp.ClientTimeout(total=5),
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
                line = f"\n\n> 💳 **${spend:.2f}** used this month · **${remaining:.2f}** remaining"
            except (TypeError, ValueError):
                line = f"\n\n> 💳 **${spend:.2f}** used this month"
        else:
            line = f"\n\n> 💳 **${spend:.2f}** used this month"

        _BUDGET_CACHE[api_key] = (now + _BUDGET_CACHE_TTL, line)
        return line

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
                # If a pipe already emitted the balance line live (Bug #139 fix),
                # don't append it a second time.
                if "used this month" in content:
                    return body
                last["content"] = content + line
            elif not content:
                # No content yet (None/empty) — just set the balance line.
                last["content"] = line.strip()
            # else: non-string content (list/dict) — leave it untouched rather
            # than clobbering it (Bug #136).

            return body
        except Exception:
            return body

    async def stream(
        self,
        event: dict,
        __user__: Optional[dict] = None,
        __event_emitter__=None,
    ) -> dict:
        # Surface the balance line live when the reply finishes (Bug #144).
        #
        # The line must land INSIDE the model's "output" (Responses API), not as
        # a side-stream "message" event. The frontend's chatCompletionEventHandler
        # runs `message.content = getOutputText(output)` on the final
        # chat:completion event, which wipes any content appended via
        # __event_emitter__("message"). Anything folded into the output survives.
        #
        # v1.3.0's delta mutation was the right idea but had a silent bug:
        # `delta = choice.get("delta") or {}` — the finish chunk has delta={}
        # (falsy), so `or {}` returned a NEW throwaway dict and the mutation
        # never touched choice["delta"]. Mutate choice["delta"] directly instead.
        try:
            if not isinstance(event, dict):
                return event
            choices = event.get("choices")
            if not choices:
                return event
            choice = choices[0]
            if choice.get("finish_reason") != "stop":
                return event
            line = await self._fetch_budget()
            if not line:
                return event
            delta = choice.get("delta")
            if delta is None:
                delta = {}
                choice["delta"] = delta
            content = delta.get("content", "")
            delta["content"] = (content + line) if isinstance(content, str) else line
            return event
        except Exception:
            return event
