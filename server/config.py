"""Application configuration loaded from YAML, env vars, and CLI args."""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass, field, fields as dataclass_fields
from pathlib import Path

import yaml


def _parse_csv_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        values = value.split(",")
    else:
        values = value
    return [str(item).strip() for item in values if str(item).strip()]


def _parse_positive_int(value, default: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def _dataclass_kwargs(cls, data: dict | None) -> dict:
    if not isinstance(data, dict):
        return {}
    valid_fields = {item.name for item in dataclass_fields(cls)}
    return {key: value for key, value in data.items() if key in valid_fields}


@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = 11451
    allowed_origins: list[str] = field(default_factory=list)
    token_expire_days: int = 30


@dataclass
class CustomRegex:
    pattern: str = ""
    platform: str = ""  # PC, KRKR, Ty, ONS, 直装
    description: str = ""


@dataclass
class ScraperConfig:
    bangumi_token: str = ""
    vndb_token: str = ""
    ymgal_client_id: str = "ymgal"
    ymgal_client_secret: str = "luna0327"
    hikarinagi_client_id: str = ""
    hikarinagi_client_secret: str = ""
    hikarinagi_scope: str = "catalog:full"


@dataclass
class Config:
    server: ServerConfig = field(default_factory=ServerConfig)
    games_path: str = "/games"
    data_path: str = "/data"
    patch_dir: str = "/steam_patch"
    steam_dir: str = ""
    proxy: str = ""
    custom_regex: list[CustomRegex] = field(default_factory=list)
    scrapers: ScraperConfig = field(default_factory=ScraperConfig)

    @property
    def database_url(self) -> str:
        """SQLite database URL. DB file is stored in data_path."""
        db_dir = Path(self.data_path)
        db_dir.mkdir(parents=True, exist_ok=True)
        return f"sqlite+aiosqlite:///{db_dir / 'sena_repo.db'}"

    @property
    def covers_path(self) -> Path:
        p = Path(self.data_path) / "covers"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def backgrounds_path(self) -> Path:
        p = Path(self.data_path) / "backgrounds"
        p.mkdir(parents=True, exist_ok=True)
        return p


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sena Repo Server")
    parser.add_argument("--host", type=str, help="Bind host")
    parser.add_argument("--port", type=int, help="Bind port")
    parser.add_argument("--games-path", type=str, help="Path to game files")
    parser.add_argument("--data-path", type=str, help="Path to data directory")
    parser.add_argument("--config", type=str, default="config.yaml", help="Config file path")
    # parse_known_args ignores unknown args (e.g. uvicorn's "main:app")
    known, _ = parser.parse_known_args()
    return known


_cached_config: Config | None = None


def _apply_persisted_scraper_config(config: Config) -> None:
    path = Path(config.data_path) / "scraper_config.json"
    if not path.is_file():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return

    fields = {
        "bangumi_token": ("scrapers", "SENA_BANGUMI_TOKEN"),
        "vndb_token": ("scrapers", "SENA_VNDB_TOKEN"),
        "ymgal_client_id": ("scrapers", "SENA_YMGAL_CLIENT_ID"),
        "ymgal_client_secret": ("scrapers", "SENA_YMGAL_CLIENT_SECRET"),
        "hikarinagi_client_id": ("scrapers", "SENA_HIKARINAGI_CLIENT_ID"),
        "hikarinagi_client_secret": ("scrapers", "SENA_HIKARINAGI_CLIENT_SECRET"),
        "hikarinagi_scope": ("scrapers", "SENA_HIKARINAGI_SCOPE"),
        "proxy": ("config", "SENA_PROXY"),
    }
    for key, (target, env_name) in fields.items():
        if os.environ.get(env_name):
            continue
        value = data.get(key)
        if not isinstance(value, str) or "****" in value:
            continue
        if target == "scrapers":
            setattr(config.scrapers, key, value)
        else:
            setattr(config, key, value)


def load_config(config_path: str | None = None) -> Config:
    """Load configuration from YAML file, env vars, and CLI args.

    Priority: CLI args and env vars > persisted scraper settings > YAML file > defaults

    Returns a singleton — subsequent calls return the same instance,
    so dynamic attributes (e.g. auto_scan) set via API are visible everywhere.
    """
    global _cached_config
    if _cached_config is not None:
        return _cached_config

    config = Config()
    args = _parse_args()

    # 1. Load YAML file if it exists
    yaml_path = config_path or args.config
    if os.path.isfile(yaml_path):
        with open(yaml_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}

        if "server" in data:
            config.server = ServerConfig(
                **_dataclass_kwargs(ServerConfig, data["server"])
            )
            config.server.allowed_origins = _parse_csv_list(config.server.allowed_origins)
            config.server.token_expire_days = _parse_positive_int(
                config.server.token_expire_days, 30
            )
        if "games_path" in data:
            config.games_path = data["games_path"]
        if "data_path" in data:
            config.data_path = data["data_path"]
        if "patch_dir" in data:
            config.patch_dir = data["patch_dir"]
        if "steam_dir" in data:
            config.steam_dir = data["steam_dir"]
        if "custom_regex" in data:
            config.custom_regex = [
                CustomRegex(**_dataclass_kwargs(CustomRegex, r))
                for r in data["custom_regex"]
                if isinstance(r, dict) and r.get("pattern")
            ]
        if "scrapers" in data:
            config.scrapers = ScraperConfig(
                **_dataclass_kwargs(ScraperConfig, data["scrapers"])
            )

    # 2. Env var overrides
    if os.environ.get("SENA_GAMES_PATH"):
        config.games_path = os.environ["SENA_GAMES_PATH"]
    if os.environ.get("SENA_DATA_PATH"):
        config.data_path = os.environ["SENA_DATA_PATH"]
    if os.environ.get("SENA_PATCH_DIR"):
        config.patch_dir = os.environ["SENA_PATCH_DIR"]
    if os.environ.get("SENA_HOST"):
        config.server.host = os.environ["SENA_HOST"]
    if os.environ.get("SENA_PORT"):
        config.server.port = int(os.environ["SENA_PORT"])
    if os.environ.get("SENA_ALLOWED_ORIGINS"):
        config.server.allowed_origins = _parse_csv_list(os.environ["SENA_ALLOWED_ORIGINS"])
    if os.environ.get("SENA_TOKEN_EXPIRE_DAYS"):
        config.server.token_expire_days = _parse_positive_int(
            os.environ["SENA_TOKEN_EXPIRE_DAYS"], config.server.token_expire_days
        )
    if os.environ.get("SENA_PROXY"):
        config.proxy = os.environ["SENA_PROXY"]

    # Scraper API keys (env vars — safer than config files)
    if os.environ.get("SENA_BANGUMI_TOKEN"):
        config.scrapers.bangumi_token = os.environ["SENA_BANGUMI_TOKEN"]
    if os.environ.get("SENA_VNDB_TOKEN"):
        config.scrapers.vndb_token = os.environ["SENA_VNDB_TOKEN"]
    if os.environ.get("SENA_YMGAL_CLIENT_ID"):
        config.scrapers.ymgal_client_id = os.environ["SENA_YMGAL_CLIENT_ID"]
    if os.environ.get("SENA_YMGAL_CLIENT_SECRET"):
        config.scrapers.ymgal_client_secret = os.environ["SENA_YMGAL_CLIENT_SECRET"]
    if os.environ.get("SENA_HIKARINAGI_CLIENT_ID"):
        config.scrapers.hikarinagi_client_id = os.environ["SENA_HIKARINAGI_CLIENT_ID"]
    if os.environ.get("SENA_HIKARINAGI_CLIENT_SECRET"):
        config.scrapers.hikarinagi_client_secret = os.environ["SENA_HIKARINAGI_CLIENT_SECRET"]
    if os.environ.get("SENA_HIKARINAGI_SCOPE"):
        config.scrapers.hikarinagi_scope = os.environ["SENA_HIKARINAGI_SCOPE"]

    # 3. CLI arg overrides
    if args.host:
        config.server.host = args.host
    if args.port:
        config.server.port = args.port
    if args.games_path:
        config.games_path = args.games_path
    if args.data_path:
        config.data_path = args.data_path

    _apply_persisted_scraper_config(config)

    _cached_config = config
    return config
