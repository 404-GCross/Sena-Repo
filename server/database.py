"""SQLAlchemy async engine and session management."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from config import Config

_engine = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


class Base(DeclarativeBase):
    pass


def init_database(config: Config):
    """Initialize the async engine and session factory."""
    global _engine, _session_factory

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
