"""SQLAlchemy async engine and session management — with sync fallback for background tasks."""

from __future__ import annotations

from contextlib import contextmanager

from sqlalchemy import create_engine as create_sync_engine
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Session

from config import Config

_engine = None
_session_factory: async_sessionmaker[AsyncSession] | None = None
_sync_session_factory: Session | None = None


class Base(DeclarativeBase):
    pass


def init_database(config: Config):
    """Initialize both async and sync engines."""
    global _engine, _session_factory, _sync_session_factory

    _engine = create_async_engine(
        config.database_url,
        echo=False,
        connect_args={"check_same_thread": False},
    )
    _session_factory = async_sessionmaker(
        _engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )
    # Sync fallback for background tasks — avoids greenlet issues
    _sync_session_factory = Session(
        create_sync_engine(
            config.database_url.replace("+aiosqlite", ""),
            echo=False,
            connect_args={"check_same_thread": False},
        ),
    )


@contextmanager
def get_sync_session():
    """Context manager: yields a synchronous database session. Use in background threads only."""
    if _sync_session_factory is None:
        raise RuntimeError("Database not initialized.")
    s = Session(bind=_sync_session_factory.get_bind())
    try:
        yield s
        s.commit()
    except Exception:
        s.rollback()
        raise
    finally:
        s.close()


async def get_session() -> AsyncSession:
    """Dependency: yields an async database session."""
    if _session_factory is None:
        raise RuntimeError("Database not initialized. Call init_database() first.")
    async with _session_factory() as session:
        try:
            yield session
        finally:
            await session.close()


async def create_tables():
    """Create all tables if they don't exist."""
    if _engine is None:
        raise RuntimeError("Database not initialized. Call init_database() first.")
    import models  # noqa: F401

    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        game_columns = {row[1] for row in await conn.exec_driver_sql("PRAGMA table_info(games)")}
        if "is_nsfw" not in game_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE games ADD COLUMN is_nsfw BOOLEAN NOT NULL DEFAULT 0"
            )
        if "hikarinagi_id" not in game_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE games ADD COLUMN hikarinagi_id VARCHAR(64)"
            )
        columns = await conn.exec_driver_sql("PRAGMA table_info(game_versions)")
        version_columns = {row[1] for row in columns}
        if "extract_password" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN extract_password VARCHAR(256)")
        if "source_type" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN source_type VARCHAR(32) NOT NULL DEFAULT 'local'")
        if "source_id" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN source_id INTEGER")
        if "source_path" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN source_path VARCHAR(1024)")
        if "checksum_algo" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN checksum_algo VARCHAR(16)")
        if "checksum" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN checksum VARCHAR(128)")
        if "checksum_updated_at" not in version_columns:
            await conn.exec_driver_sql("ALTER TABLE game_versions ADD COLUMN checksum_updated_at DATETIME")

        columns = await conn.exec_driver_sql("PRAGMA table_info(game_tags)")
        game_tag_columns = {row[1] for row in columns}
        if "source" not in game_tag_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE game_tags ADD COLUMN source VARCHAR(32) NOT NULL DEFAULT 'user'"
            )
        if "weight" not in game_tag_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE game_tags ADD COLUMN weight FLOAT NOT NULL DEFAULT 0"
            )
        if "is_spoiler" not in game_tag_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE game_tags ADD COLUMN is_spoiler BOOLEAN NOT NULL DEFAULT 0"
            )

        columns = await conn.exec_driver_sql("PRAGMA table_info(root_directories)")
        root_columns = {row[1] for row in columns}
        if "source_type" not in root_columns:
            await conn.exec_driver_sql("ALTER TABLE root_directories ADD COLUMN source_type VARCHAR(32) NOT NULL DEFAULT 'local'")
        if "source_id" not in root_columns:
            await conn.exec_driver_sql("ALTER TABLE root_directories ADD COLUMN source_id INTEGER")
        if "source_name" not in root_columns:
            await conn.exec_driver_sql("ALTER TABLE root_directories ADD COLUMN source_name VARCHAR(255)")
        if "source_path" not in root_columns:
            await conn.exec_driver_sql("ALTER TABLE root_directories ADD COLUMN source_path VARCHAR(1024)")
        await conn.exec_driver_sql(
            """
            UPDATE root_directories
            SET source_path = substr(path, length('openlist://') + instr(substr(path, length('openlist://') + 1), '/'))
            WHERE source_type = 'openlist'
              AND (source_path IS NULL OR source_path = '')
              AND path LIKE 'openlist://%/%'
            """
        )

        columns = await conn.exec_driver_sql("PRAGMA table_info(steam_patch_roots)")
        steam_patch_root_columns = {row[1] for row in columns}
        if "analysis_mode" not in steam_patch_root_columns:
            await conn.exec_driver_sql(
                "ALTER TABLE steam_patch_roots ADD COLUMN analysis_mode VARCHAR(32) NOT NULL DEFAULT 'auto'"
            )
            await conn.exec_driver_sql(
                "UPDATE steam_patch_roots SET analysis_mode = 'manual' WHERE source_type = 'openlist'"
            )

        # ── users.role migration (v2) ──────────────────────────────────────
        user_cols = {row[1] for row in await conn.exec_driver_sql("PRAGMA table_info(users)")}
        if "role" not in user_cols:
            await conn.exec_driver_sql(
                "ALTER TABLE users ADD COLUMN role VARCHAR(16) NOT NULL DEFAULT 'user'"
            )
            # promote existing admins
            await conn.exec_driver_sql("UPDATE users SET role = 'admin' WHERE is_admin = 1")
            # first admin becomes owner
            await conn.exec_driver_sql(
                "UPDATE users SET role = 'owner' WHERE id = "
                "(SELECT MIN(id) FROM users WHERE is_admin = 1)"
            )
        # Keep the oldest owner when upgrading databases created before the
        # owner uniqueness guard was added.
        await conn.exec_driver_sql(
            """
            UPDATE users
            SET role = 'admin', is_admin = 1
            WHERE role = 'owner'
              AND id != (SELECT MIN(id) FROM users WHERE role = 'owner')
            """
        )
        await conn.exec_driver_sql(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_users_owner_role
            ON users (role)
            WHERE role = 'owner'
            """
        )
        from utils.secrets import encrypt_secret, is_encrypted

        source_rows = await conn.exec_driver_sql(
            "SELECT id, password FROM file_sources WHERE password IS NOT NULL AND password != ''"
        )
        for source_id, password in source_rows:
            if not is_encrypted(password):
                await conn.exec_driver_sql(
                    "UPDATE file_sources SET password = ? WHERE id = ?",
                    (encrypt_secret(password), source_id),
                )
        await conn.exec_driver_sql(
            "CREATE INDEX IF NOT EXISTS ix_user_sessions_user_id ON user_sessions (user_id)"
        )
        await conn.exec_driver_sql(
            "CREATE UNIQUE INDEX IF NOT EXISTS ix_user_sessions_token_hash ON user_sessions (token_hash)"
        )


async def get_engine():
    if _engine is None:
        raise RuntimeError("Database not initialized.")
    return _engine
