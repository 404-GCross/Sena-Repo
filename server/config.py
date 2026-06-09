"""Application configuration loaded from YAML, env vars, and CLI args."""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from pathlib import Path

import yaml


@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = 11451


@dataclass
class CustomRegex:
    pattern: str = ""
    platform: str = ""  # PC, KRKR, Ty, ONS, 直装
    description: str = ""


@dataclass
class ScraperConfig:
    bangumi_token: str = ""
    vndb_token: str = ""
    igdb_client_id: str = ""
    igdb_client_secret: str = ""


@dataclass
class Config:
    server: ServerConfig = field(default_factory=ServerConfig)
    games_path: str = "/games"
    data_path: str = "/data"
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


def load_config(config_path: str | None = None) -> Config:
    """Load configuration from YAML file, env vars, and CLI args.

    Priority: CLI args > env vars > YAML file > defaults
    """
    config = Config()
    args = _parse_args()

    # 1. Load YAML file if it exists
    yaml_path = config_path or args.config
    if os.path.isfile(yaml_path):
        with open(yaml_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}

        if "server" in data:
            config.server = ServerConfig(**data["server"])
        if "games_path" in data:
            config.games_path = data["games_path"]
        if "data_path" in data:
            config.data_path = data["data_path"]
        if "custom_regex" in data:
            config.custom_regex = [
                CustomRegex(**r) for r in data["custom_regex"] if r.get("pattern")
            ]
        if "scrapers" in data:
            config.scrapers = ScraperConfig(**data["scrapers"])

    # 2. Env var overrides
    if os.environ.get("SENA_GAMES_PATH"):
        config.games_path = os.environ["SENA_GAMES_PATH"]
    if os.environ.get("SENA_DATA_PATH"):
        config.data_path = os.environ["SENA_DATA_PATH"]
    if os.environ.get("SENA_HOST"):
        config.server.host = os.environ["SENA_HOST"]
    if os.environ.get("SENA_PORT"):
        config.server.port = int(os.environ["SENA_PORT"])
    if os.environ.get("SENA_PROXY"):
        config.proxy = os.environ["SENA_PROXY"]

    # Scraper API keys (env vars — safer than config files)
    if os.environ.get("SENA_BANGUMI_TOKEN"):
        config.scrapers.bangumi_token = os.environ["SENA_BANGUMI_TOKEN"]
    if os.environ.get("SENA_VNDB_TOKEN"):
        config.scrapers.vndb_token = os.environ["SENA_VNDB_TOKEN"]
    if os.environ.get("SENA_IGDB_CLIENT_ID"):
        config.scrapers.igdb_client_id = os.environ["SENA_IGDB_CLIENT_ID"]
    if os.environ.get("SENA_IGDB_CLIENT_SECRET"):
        config.scrapers.igdb_client_secret = os.environ["SENA_IGDB_CLIENT_SECRET"]

    # 3. CLI arg overrides
    if args.host:
        config.server.host = args.host
    if args.port:
        config.server.port = args.port
    if args.games_path:
        config.games_path = args.games_path
    if args.data_path:
        config.data_path = args.data_path

    return config
