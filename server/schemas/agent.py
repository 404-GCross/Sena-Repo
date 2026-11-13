from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, field_validator


class AgentSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool = False
    provider: str = Field(default="openai", max_length=40)
    protocol: Literal["chat", "responses", "anthropic", "gemini", "ollama"] = "chat"
    base_url: str = Field(default="https://api.openai.com/v1", max_length=2048)
    model: str = Field(default="", max_length=200)
    api_key: str | None = Field(default=None, max_length=4096)
    proxy_mode: Literal["direct", "inherit", "custom"] = "direct"
    proxy_url: str = Field(default="", max_length=2048)
    proxy_username: str = Field(default="", max_length=256)
    proxy_password: str | None = Field(default=None, max_length=4096)
    vision: bool = False
    timeout: int = Field(default=90, ge=10, le=300)
    max_calls: int = Field(default=200, ge=1, le=2000)
    max_tokens: int = Field(default=200000, ge=1000, le=2000000)
    rounds: int = Field(default=8, ge=2, le=20)
    cover_language: Literal["zh", "original", "source"] = "zh"
    cover_fallback: Literal["original", "keep", "review"] = "original"
    portrait: bool = True
    high_resolution: bool = True
    name_language: Literal["zh", "original", "source"] = "zh"
    translate_description: bool = False
    preferences: str = Field(default="", max_length=3000)
    patch_preferences: str = Field(default="", max_length=3000)
    patch_steam_name: bool = True
    update_mode: Literal["missing", "overwrite"] = "missing"
    game_ask: bool = True
    patch_ask: bool = True
    game_default: Literal["regular", "agent"] = "regular"
    patch_default: Literal["regular", "agent"] = "regular"
    scheduled_game: Literal["regular", "agent"] = "regular"
    scheduled_patch: Literal["regular", "agent"] = "regular"
    remote_archive_mb: int = Field(default=64, ge=0, le=512)

    @field_validator("base_url", "proxy_url")
    @classmethod
    def validate_url(cls, value, info):
        if not value and info.field_name == "proxy_url":
            return ""
        url = urlsplit(value)
        schemes = (
            {"http", "https"}
            if info.field_name == "base_url"
            else {"http", "https", "socks5", "socks5h"}
        )
        if (
            url.scheme not in schemes
            or not url.hostname
            or url.username
            or url.password
            or url.query
            or url.fragment
        ):
            raise ValueError(
                "地址必须是无凭据和查询参数的 HTTP/HTTPS 地址（代理可使用 SOCKS5）"
            )
        return value.rstrip("/")


class AgentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["game", "patch", "scrape"]
    root_ids: list[int] = Field(default_factory=list, max_length=1000)
    game_ids: list[int] = Field(default_factory=list, max_length=10000)
    patch_keys: list[str] = Field(default_factory=list, max_length=10000)
    retry: bool = False


class IgnoreResults(BaseModel):
    ids: list[int] = Field(min_length=1, max_length=1000)
