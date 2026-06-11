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
    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_engine():
    if _engine is None:
        raise RuntimeError("Database not initialized.")
    return _engine
