from __future__ import annotations

import asyncio
import json
from pathlib import Path

from models.user import User
from services.agent.providers import ModelClient, ModelError, tool_spec
from services.agent.settings import load_settings


class AgentStopped(Exception):
    pass


class AgentBudget(ModelError):
    pass


class Runtime:
    def __init__(self, session, job, settings, revision):
        self.session, self.job, self.settings, self.revision = (
            session,
            job,
            settings,
            revision,
        )
        self.client = ModelClient(settings)

    async def check(self, *, model=False):
        await self.session.refresh(self.job)
        if self.job.cancel_requested:
            raise AgentStopped()
        if self.job.actor_id is not None:
            actor = await self.session.get(
                User, self.job.actor_id, populate_existing=True
            )
            if actor is None or actor.role != "admin" or actor.status != "active":
                raise AgentStopped()
        settings, revision = await load_settings(self.session)
        if not settings.enabled:
            raise AgentStopped()
        if model and revision != self.revision:
            excluded = {
                "game_ask",
                "patch_ask",
                "game_default",
                "patch_default",
                "scheduled_game",
                "scheduled_patch",
            }
            if settings.model_dump(exclude=excluded) != self.settings.model_dump(
                exclude=excluded
            ):
                raise AgentBudget("模型配置已变化，剩余项目使用常规处理")
        if model and (
            self.job.calls >= self.settings.max_calls
            or self.job.tokens >= self.settings.max_tokens
        ):
            raise AgentBudget("模型预算已用完，剩余项目使用常规处理")

    async def reason(
        self,
        skill: str,
        context: dict,
        schema: dict,
        tools: dict | None = None,
        images=None,
    ):
        prompt = (Path(__file__).parent / "skills" / f"{skill}.md").read_text()
        messages = [
            {
                "role": "system",
                "content": prompt
                + " Use the submit tool for the final structured result. No filesystem or network access except supplied tools.",
            },
            {
                "role": "user",
                "content": json.dumps(context, ensure_ascii=False),
                "images": images or [],
            },
        ]
        tools = tools or {}
        specs = [entry[0] for entry in tools.values()] + [
            tool_spec("submit", "Submit verified result or unresolved items", schema)
        ]
        for _ in range(self.settings.rounds):
            await self.check(model=True)
            self.job.calls += 1
            await self.session.commit()
            result, tokens = await self.client.turn(messages, specs)
            self.job.tokens += max(
                tokens,
                (len(messages[-1].get("content", "")) + len(result.get("content", "")))
                // 4,
            )
            await self.session.commit()
            await self.check()
            messages.append(result)
            calls = result.get("calls", [])[:8]
            if not calls:
                messages.append(
                    {
                        "role": "user",
                        "content": "Use a supplied tool. Finish using submit.",
                    }
                )
                continue
            for call in calls:
                if call["name"] == "submit":
                    return call["arguments"]
                await self.check()
                if call["name"] not in tools:
                    output = {"error": "Unknown tool"}
                else:
                    try:
                        output = await asyncio.wait_for(
                            tools[call["name"]][1](call["arguments"]), timeout=120
                        )
                    except (AgentStopped, AgentBudget):
                        raise
                    except Exception:
                        output = {
                            "error": "Tool could not verify requested data; use another candidate or mark unresolved"
                        }
                images = output.pop("_images", []) if isinstance(output, dict) else []
                content = json.dumps(output, ensure_ascii=False)
                if len(content) > 48000:
                    content = json.dumps(
                        {"truncated": True, "preview": content[:46000]},
                        ensure_ascii=False,
                    )
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "name": call["name"],
                        "content": content,
                    }
                )
                if images:
                    messages.append(
                        {
                            "role": "user",
                            "content": "Inspected candidate images, in the order reported by the tool.",
                            "images": images,
                        }
                    )
        raise ModelError("智能分析达到调用轮数上限")


def object_schema(properties: dict, required=None):
    return {
        "type": "object",
        "properties": properties,
        "required": list(properties) if required is None else required,
        "additionalProperties": False,
    }
