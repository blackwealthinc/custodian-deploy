"""
title: Custodian Video
author: Custodian
description: Creates a short video from your description.
version: 1.4.0
"""

from pydantic import BaseModel
import aiohttp
import asyncio
import io
from urllib.parse import quote

from fastapi import UploadFile
from open_webui.routers.images import get_image_config
from open_webui.routers.files import upload_file_handler
from open_webui.models.users import UserModel
from open_webui.models.chats import Chats


def _first_object(payload):
    """LiteLLM wraps /videos responses in an OpenAI-style {"data": [...]} envelope."""
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list) and data:
            return data[0]
    return payload if isinstance(payload, dict) else {}


class Pipe:
    class Valves(BaseModel):
        # MODEL is the LiteLLM model_name (NOT the full provider path).
        MODEL: str = "custodian-video"
        SIZE: str = "1280x720"
        SECONDS: str = "8"

    def __init__(self):
        self.valves = self.Valves()

    async def _fetch_budget_line(self) -> str:
        """Read the customer's live spend from LiteLLM /key/info and format the
        balance line. Fails closed (empty string) so a LiteLLM outage never breaks
        the reply. Same source as the budget filter — one key = one budget."""
        try:
            image_config = await get_image_config()
            base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
            api_key = image_config.IMAGES_OPENAI_API_KEY
            if not base_url or not api_key:
                return ""
            root = base_url[:-3] if base_url.endswith("/v1") else base_url
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{root}/key/info",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as response:
                    if response.status != 200:
                        return ""
                    data = await response.json()
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
        except Exception:
            return ""

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

        # 2. Read the customer's key + LiteLLM URL from the image config
        #    (same source as images/vision — one key = one budget).
        image_config = await get_image_config()
        base_url = (image_config.IMAGES_OPENAI_API_BASE_URL or "").rstrip("/")
        api_key = image_config.IMAGES_OPENAI_API_KEY

        if not base_url or not api_key:
            return "Video isn't configured yet. Please try again shortly."

        # 3. Generate the video through LiteLLM (unified /videos surface).
        video_bytes = None
        try:
            async with aiohttp.ClientSession() as session:
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

                # Poll until done (Veo is async — can take 30s–2min).
                for _ in range(24):
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

                # Download the finished video bytes.
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

        # 4. Persist the video as a real File so it's downloadable (and governed
        #    by the upload/autodelete cleanup). Fix for Bug #131 / #133 / #137.
        #
        #    __user__ arrives as a dict (user.model_dump()) in pipe context, but
        #    upload_file_handler() needs a UserModel (it reads user.id).
        #    Reconstruct it. We call upload_file_handler() directly (instead of
        #    upload_image()) so we can supply a real filename — upload_image()
        #    hardcodes "generated-image.mp4", which is what the download would
        #    otherwise be saved as (Bug #137).
        user_obj = None
        try:
            if isinstance(__user__, dict) and __user__.get("id"):
                user_obj = UserModel(**__user__)
        except Exception:
            user_obj = None

        if __request__ is None or user_obj is None:
            return "Your video was created, but I couldn't attach it. Please try again."

        metadata = __metadata__ if isinstance(__metadata__, dict) else {}

        try:
            file = UploadFile(
                file=io.BytesIO(video_bytes),
                filename="video.mp4",
                headers={"content-type": "video/mp4"},
            )
            file_item = await upload_file_handler(
                request=__request__,
                file=file,
                metadata=metadata,
                process=False,
                user=user_obj,
            )

            # Link the file to the chat message (the same step upload_image()
            # does) so the video also shows up in the chat's file browser.
            chat_id = metadata.get("chat_id")
            message_id = metadata.get("message_id")
            if file_item and file_item.id and chat_id and message_id:
                await Chats.insert_chat_files(
                    chat_id=chat_id,
                    message_id=message_id,
                    file_ids=[file_item.id],
                    user_id=user_obj.id,
                )

            url = __request__.app.url_path_for("get_file_content_by_id", id=file_item.id)
        except Exception:
            return "Your video was created, but I couldn't attach it. Please try again."

        # 5. Read the live balance AFTER generation so the spend reflects this
        #    video (Bug #139 — the budget line must be part of the live reply,
        #    not appended later by the outlet filter).
        budget_line = await self._fetch_budget_line()

        # 6. Emit the video as a rich embed so it plays inline (Bug #140).
        #    v0.11.0 has no native <video> path in the message renderer — the
        #    "embeds" event renders arbitrary HTML in a sandboxed iframe, and the
        #    file URL resolves against the WebUI origin when
        #    DEFAULT_INTERFACE_SETTINGS.iframeSandboxAllowSameOrigin is true
        #    (set in the compose file alongside the v0.11.1 upgrade).
        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Video created", "done": True}}
            )
            embed_html = (
                '<div style="max-width:480px;font-family:-apple-system,BlinkMacSystemFont,sans-serif">'
                f'<video controls preload="metadata" width="100%" src="{url}" '
                'style="border-radius:12px;background:#000;max-height:420px;width:100%"></video>'
                '<div style="margin-top:8px;font-size:13px;color:#888">'
                f'<a href="{url}" download style="color:#4a90d9;text-decoration:none">Download video</a>'
                "</div></div>"
            )
            await __event_emitter__(
                {"type": "embeds", "data": {"embeds": [embed_html]}}
            )

        # 7. Return a non-empty confirmation carrying the balance line. This is
        #    the live reply content (shown when the video finishes), so the
        #    budget appears with the video — no reload required.
        return f"Video created ✓{budget_line}"
