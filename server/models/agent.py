from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Integer, JSON, String, Text

from database import Base


class AgentConfig(Base):
    __tablename__ = "agent_config"
    id = Column(Integer, primary_key=True, default=1)
    revision = Column(Integer, nullable=False, default=0)
    settings = Column(JSON, nullable=False, default=dict)


class AgentJob(Base):
    __tablename__ = "agent_jobs"
    id = Column(Integer, primary_key=True)
    actor_id = Column(Integer, nullable=True)
    kind = Column(String(16), nullable=False)
    status = Column(String(24), nullable=False, default="pending")
    request = Column(JSON, nullable=False, default=dict)
    calls = Column(Integer, nullable=False, default=0)
    tokens = Column(Integer, nullable=False, default=0)
    cancel_requested = Column(Boolean, nullable=False, default=False)
    message = Column(Text, nullable=False, default="")
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    finished_at = Column(DateTime, nullable=True)


class AgentResult(Base):
    __tablename__ = "agent_results"
    id = Column(Integer, primary_key=True)
    job_id = Column(Integer, nullable=False, index=True)
    key = Column(String(1024), nullable=False)
    fingerprint = Column(String(64), nullable=False, index=True)
    status = Column(String(24), nullable=False)
    summary = Column(Text, nullable=False, default="")
    data = Column(JSON, nullable=False, default=dict)
