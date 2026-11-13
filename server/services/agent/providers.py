from __future__ import annotations

import json
import secrets
from urllib.parse import quote

import httpx

from schemas.agent import AgentSettings
from services.agent.settings import client_options


class ModelError(RuntimeError):
    pass


def tool_spec(name: str, description: str, parameters: dict) -> dict:
    return {"name": name, "description": description, "parameters": parameters}


def _arguments(value):
    if isinstance(value, dict):
        return value
    try:
        result = json.loads(value)
        return result if isinstance(result, dict) else {}
    except (TypeError, ValueError):
        return {}


class ModelClient:
    def __init__(self, settings: AgentSettings):
        self.settings = settings

    async def request(
        self, method: str, path: str, payload: dict | None = None
    ) -> dict:
        s = self.settings
        headers = {"Accept": "application/json"}
        if s.api_key:
            headers[
                "x-api-key"
                if s.protocol == "anthropic"
                else "x-goog-api-key"
                if s.protocol == "gemini"
                else "Authorization"
            ] = (
                s.api_key
                if s.protocol in {"anthropic", "gemini"}
                else f"Bearer {s.api_key}"
            )
        if s.protocol == "anthropic":
            headers["anthropic-version"] = "2023-06-01"
        try:
            async with httpx.AsyncClient(**client_options(s)) as client:
                async with client.stream(
                    method, s.base_url + path, json=payload, headers=headers
                ) as response:
                    if response.status_code != 200:
                        raise ModelError(
                            f"模型服务请求失败（HTTP {response.status_code}），请检查协议、凭据与模型 ID"
                        )
                    chunks = bytearray()
                    async for chunk in response.aiter_bytes():
                        chunks.extend(chunk)
                        if len(chunks) > 4 * 1024 * 1024:
                            raise ModelError("模型响应过大")
                    result = json.loads(chunks)
                    if not isinstance(result, dict):
                        raise ValueError()
                    return result
        except (httpx.HTTPError, ValueError) as exc:
            raise ModelError(f"模型连接或响应异常（{type(exc).__name__}）") from None

    async def models(self) -> list[str]:
        s = self.settings
        path = (
            "/api/tags"
            if s.protocol == "ollama"
            else "/v1/models"
            if s.protocol == "anthropic" and not s.base_url.endswith("/v1")
            else "/models"
        )
        data = await self.request("GET", path)
        rows = (
            data.get("models", [])
            if s.protocol in {"gemini", "ollama"}
            else data.get("data", [])
        )
        return [
            str(r.get("id") or r.get("name") or "").removeprefix("models/")
            for r in rows[:500]
            if isinstance(r, dict)
        ]

    async def turn(self, messages: list[dict], tools: list[dict]) -> tuple[dict, int]:
        try:
            return await self._turn(messages, tools)
        except (KeyError, IndexError, TypeError, AttributeError, ValueError):
            raise ModelError("模型返回了无效的消息或工具调用") from None

    async def _turn(self, messages: list[dict], tools: list[dict]) -> tuple[dict, int]:
        s = self.settings
        if not s.model:
            raise ModelError("未配置模型 ID")
        functions = [{"type": "function", "function": t} for t in tools]
        if s.protocol in {"chat", "ollama"}:
            rows = []
            for m in messages:
                row = {
                    k: v
                    for k, v in m.items()
                    if k in {"role", "content", "tool_call_id"}
                }
                if s.protocol == "ollama" and m["role"] == "tool":
                    row["tool_name"] = m.get("name", "")
                if m.get("reasoning_content") is not None:
                    row["reasoning_content"] = m["reasoning_content"]
                if m.get("calls"):
                    row["tool_calls"] = [
                        {
                            "id": c["id"],
                            "type": "function",
                            "function": {
                                "name": c["name"],
                                "arguments": c["arguments"]
                                if s.protocol == "ollama"
                                else json.dumps(c["arguments"], ensure_ascii=False),
                            },
                        }
                        for c in m["calls"]
                    ]
                if m.get("images"):
                    if s.protocol == "ollama":
                        row["images"] = [
                            image.split(",", 1)[1] for image in m["images"]
                        ]
                    else:
                        row["content"] = [{"type": "text", "text": m["content"]}] + [
                            {"type": "image_url", "image_url": {"url": image}}
                            for image in m["images"]
                        ]
                rows.append(row)
            payload = {
                "model": s.model,
                "messages": rows,
                "tools": functions,
                "stream": False,
            }
            if s.protocol == "ollama":
                payload["options"] = {"num_predict": 4096}
            else:
                payload[
                    "max_completion_tokens" if s.provider == "openai" else "max_tokens"
                ] = 4096
            data = await self.request(
                "POST",
                "/api/chat" if s.protocol == "ollama" else "/chat/completions",
                payload,
            )
            try:
                result = (
                    data["message"]
                    if s.protocol == "ollama"
                    else data["choices"][0]["message"]
                )
                calls = [
                    {
                        "id": c.get("id") or secrets.token_hex(8),
                        "name": c["function"]["name"],
                        "arguments": _arguments(c["function"].get("arguments")),
                    }
                    for c in result.get("tool_calls", [])
                ]
                usage = data.get("usage") or {}
                return {
                    "role": "assistant",
                    "content": result.get("content") or "",
                    "calls": calls,
                    "reasoning_content": result.get("reasoning_content"),
                }, int(
                    usage.get("total_tokens")
                    or (data.get("prompt_eval_count", 0) + data.get("eval_count", 0))
                )
            except (KeyError, IndexError, TypeError, ValueError):
                raise ModelError("模型返回了无效的消息") from None
        if s.protocol == "responses":
            rows = []
            for m in messages:
                if m.get("response_output"):
                    rows.extend(m["response_output"])
                elif m["role"] == "tool":
                    rows.append(
                        {
                            "type": "function_call_output",
                            "call_id": m["tool_call_id"],
                            "output": m["content"],
                        }
                    )
                elif m.get("calls"):
                    rows.extend(
                        {
                            "type": "function_call",
                            "call_id": c["id"],
                            "name": c["name"],
                            "arguments": json.dumps(c["arguments"]),
                        }
                        for c in m["calls"]
                    )
                else:
                    content = m["content"]
                    if m.get("images"):
                        content = [{"type": "input_text", "text": content}] + [
                            {"type": "input_image", "image_url": i} for i in m["images"]
                        ]
                    rows.append({"role": m["role"], "content": content})
            data = await self.request(
                "POST",
                "/responses",
                {
                    "model": s.model,
                    "input": rows,
                    "tools": [{"type": "function", **t} for t in tools],
                    "max_output_tokens": 4096,
                    "store": False,
                    "include": ["reasoning.encrypted_content"],
                },
            )
            calls = [
                {
                    "id": r["call_id"],
                    "name": r["name"],
                    "arguments": _arguments(r.get("arguments")),
                }
                for r in data.get("output", [])
                if r.get("type") == "function_call"
            ]
            text = "\n".join(
                c.get("text", "")
                for r in data.get("output", [])
                if r.get("type") == "message"
                for c in r.get("content", [])
            )
            return {
                "role": "assistant",
                "content": text,
                "calls": calls,
                "response_output": data.get("output", []),
            }, int((data.get("usage") or {}).get("total_tokens") or 0)
        system = "\n".join(m["content"] for m in messages if m["role"] == "system")
        if s.protocol == "anthropic":
            rows = []
            for m in messages:
                if m["role"] == "system":
                    continue
                if m["role"] == "tool":
                    role, content = (
                        "user",
                        [
                            {
                                "type": "tool_result",
                                "tool_use_id": m["tool_call_id"],
                                "content": m["content"],
                            }
                        ],
                    )
                else:
                    role = m["role"]
                    content = (
                        [{"type": "text", "text": m["content"]}]
                        if m.get("content")
                        else []
                    )
                    content += [
                        {
                            "type": "tool_use",
                            "id": c["id"],
                            "name": c["name"],
                            "input": c["arguments"],
                        }
                        for c in m.get("calls", [])
                    ]
                    content += [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": i.split(";")[0][5:],
                                "data": i.split(",", 1)[1],
                            },
                        }
                        for i in m.get("images", [])
                    ]
                if rows and rows[-1]["role"] == role:
                    rows[-1]["content"].extend(content)
                else:
                    rows.append({"role": role, "content": content})
            data = await self.request(
                "POST",
                "/messages" if s.base_url.endswith("/v1") else "/v1/messages",
                {
                    "model": s.model,
                    "system": system,
                    "messages": rows,
                    "tools": [
                        {
                            "name": t["name"],
                            "description": t["description"],
                            "input_schema": t["parameters"],
                        }
                        for t in tools
                    ],
                    "max_tokens": 4096,
                },
            )
            calls = [
                {
                    "id": r["id"],
                    "name": r["name"],
                    "arguments": _arguments(r.get("input")),
                }
                for r in data.get("content", [])
                if r.get("type") == "tool_use"
            ]
            usage = data.get("usage") or {}
            return {
                "role": "assistant",
                "content": "\n".join(
                    r.get("text", "")
                    for r in data.get("content", [])
                    if r.get("type") == "text"
                ),
                "calls": calls,
            }, int(usage.get("input_tokens", 0) + usage.get("output_tokens", 0))
        rows = []
        for m in messages:
            if m["role"] == "system":
                continue
            if m.get("gemini_parts"):
                role, parts = "model", m["gemini_parts"]
            elif m["role"] == "tool":
                role, parts = (
                    "user",
                    [
                        {
                            "functionResponse": {
                                "name": m["name"],
                                "response": {"result": m["content"]},
                            }
                        }
                    ],
                )
            else:
                role = "model" if m["role"] == "assistant" else "user"
                parts = [{"text": m["content"]}] if m.get("content") else []
                parts += [
                    {"functionCall": {"name": c["name"], "args": c["arguments"]}}
                    for c in m.get("calls", [])
                ]
                parts += [
                    {
                        "inlineData": {
                            "mimeType": i.split(";")[0][5:],
                            "data": i.split(",", 1)[1],
                        }
                    }
                    for i in m.get("images", [])
                ]
            if rows and rows[-1]["role"] == role:
                rows[-1]["parts"].extend(parts)
            else:
                rows.append({"role": role, "parts": parts})
        data = await self.request(
            "POST",
            "/models/"
            + quote(s.model.removeprefix("models/"), safe="")
            + ":generateContent",
            {
                "systemInstruction": {"parts": [{"text": system}]},
                "contents": rows,
                "tools": [{"functionDeclarations": tools}],
                "generationConfig": {"maxOutputTokens": 4096},
            },
        )
        parts = ((data.get("candidates") or [{}])[0].get("content") or {}).get(
            "parts", []
        )
        calls = [
            {
                "id": secrets.token_hex(8),
                "name": p["functionCall"]["name"],
                "arguments": _arguments(p["functionCall"].get("args")),
            }
            for p in parts
            if "functionCall" in p
        ]
        return {
            "role": "assistant",
            "content": "\n".join(p.get("text", "") for p in parts),
            "calls": calls,
            "gemini_parts": parts,
        }, int((data.get("usageMetadata") or {}).get("totalTokenCount") or 0)
