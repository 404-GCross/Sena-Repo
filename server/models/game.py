"""Game and GameVersion models."""

from __future__ import annotations

import enum
from datetime import datetime

from sqlalchemy import (
    Column,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    String,
    Text,
    Boolean,
    BigInteger,
)
from sqlalchemy.orm import relationship

from database import Base


class Platform(str, enum.Enum):
    PC = "PC"
    KRKR = "KRKR"
    TYRANOR = "Ty"
    ONS = "ONS"
    DIRECT = "直装"


class Company(Base):
    __tablename__ = "companies"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(255), nullable=False, unique=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    games = relationship("Game", back_populates="company")


class Game(Base):
    __tablename__ = "games"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(512), nullable=False)
    company_id = Column(Integer, ForeignKey("companies.id"), nullable=True)
    root_id = Column(Integer, ForeignKey("root_directories.id"), nullable=False)
    folder_path = Column(String(1024), nullable=False, unique=True)

    # Metadata (populated by scrapers in Phase 2)
    cover_path = Column(String(1024), nullable=True)
    bg_path = Column(String(1024), nullable=True)
    developer = Column(String(512), nullable=True)
    description = Column(Text, nullable=True)
    release_date = Column(String(64), nullable=True)
    vndb_id = Column(String(32), nullable=True)
    steam_id = Column(String(32), nullable=True)
    bangumi_id = Column(String(32), nullable=True)

    length = Column(Integer, default=0)
    length_minutes = Column(Integer, default=0)

    is_deleted = Column(Boolean, default=False)
    imported_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    company = relationship("Company", back_populates="games")
    versions = relationship("GameVersion", back_populates="game", cascade="all, delete-orphan")
    tags = relationship("GameTag", back_populates="game", cascade="all, delete-orphan")


class GameVersion(Base):
    __tablename__ = "game_versions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    game_id = Column(Integer, ForeignKey("games.id"), nullable=False)
    platform = Column(Enum(Platform), nullable=False)
    filename = Column(String(512), nullable=False)
    file_path = Column(String(1024), nullable=False)
    source_type = Column(String(32), nullable=False, default="local")
    source_id = Column(Integer, nullable=True)
    source_path = Column(String(1024), nullable=True)
    file_size = Column(BigInteger, default=0)
    extract_password = Column(String(256), nullable=True)

    game = relationship("Game", back_populates="versions")


class GameTag(Base):
    __tablename__ = "game_tags"

    id = Column(Integer, primary_key=True, autoincrement=True)
    game_id = Column(Integer, ForeignKey("games.id"), nullable=False)
    tag_id = Column(Integer, ForeignKey("tags.id"), nullable=False)

    game = relationship("Game", back_populates="tags")
    tag = relationship("Tag", back_populates="games")
