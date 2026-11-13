from urllib.parse import quote, urlsplit, urlunsplit

from sqlalchemy.ext.asyncio import AsyncSession

from config import load_config
from models.agent import AgentConfig
from schemas.agent import AgentSettings
from utils.secrets import decrypt_secret, encrypt_secret


async def load_settings(session: AsyncSession) -> tuple[AgentSettings, int]:
    row = await session.get(AgentConfig, 1, populate_existing=True)
    values = dict(row.settings) if row else {}
    for key in ("api_key", "proxy_password"):
        if values.get(key):
            values[key] = decrypt_secret(values[key])
    return AgentSettings.model_validate(values), row.revision if row else 0


async def save_settings(session: AsyncSession, value: AgentSettings) -> int:
    row = await session.get(AgentConfig, 1)
    previous = dict(row.settings) if row else {}
    data = value.model_dump()
    for key in ("api_key", "proxy_password"):
        fields = (
            ("base_url", "protocol")
            if key == "api_key"
            else ("proxy_url", "proxy_username")
        )
        same_destination = all(
            data.get(field) == previous.get(field) for field in fields
        )
        if data[key] is None:
            data[key] = previous.get(key, "") if same_destination else ""
        else:
            data[key] = encrypt_secret(data[key])
    if row is None:
        row = AgentConfig(id=1, revision=0)
        session.add(row)
    row.settings = data
    row.revision += 1
    await session.commit()
    return row.revision


def public_settings(value: AgentSettings, revision: int) -> dict:
    data = value.model_dump(exclude={"api_key", "proxy_password"})
    return {
        **data,
        "has_api_key": bool(value.api_key),
        "has_proxy_password": bool(value.proxy_password),
        "revision": revision,
    }


def client_options(value: AgentSettings) -> dict:
    proxy = None
    if value.proxy_mode == "inherit":
        proxy = load_config().proxy or None
    elif value.proxy_mode == "custom":
        if not value.proxy_url:
            raise ValueError("请填写智能体代理地址")
        url = urlsplit(value.proxy_url)
        auth = ""
        if value.proxy_username:
            auth = (
                quote(value.proxy_username, safe="")
                + ":"
                + quote(value.proxy_password or "", safe="")
                + "@"
            )
        proxy = urlunsplit((url.scheme, auth + url.netloc, url.path, "", ""))
    return {
        "timeout": value.timeout,
        "trust_env": False,
        "follow_redirects": False,
        "proxy": proxy,
    }
