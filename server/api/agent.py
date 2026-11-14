from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import require_admin
from config import load_config
from database import get_session
from models.agent import AgentJob, AgentResult
from models.user import User
from schemas.agent import AgentRequest, AgentSettings, IgnoreResults
from services.agent.jobs import launch
from services.agent.providers import ModelClient, ModelError, tool_spec
from services.agent.runtime import object_schema
from services.agent.settings import load_settings, public_settings, save_settings
from utils.process_lock import process_lock

router = APIRouter(
    prefix="/api/agent", tags=["agent"], dependencies=[Depends(require_admin)]
)
REVIEW_STATUSES = (
    "review",
    "fallback",
    "partial",
    "unmatched",
    "budget_fallback",
    "model_fallback",
    "validation_fallback",
    "config_fallback",
    "source_fallback",
)


@router.get("/settings")
async def settings(session: AsyncSession = Depends(get_session)):
    value, revision = await load_settings(session)
    return public_settings(value, revision)


@router.put("/settings")
async def update_settings(
    body: AgentSettings, session: AsyncSession = Depends(get_session)
):
    revision = await save_settings(session, body)
    if not body.enabled:
        jobs = (
            await session.execute(
                select(AgentJob).where(AgentJob.status.in_(["pending", "running"]))
            )
        ).scalars()
        for job in jobs:
            job.cancel_requested = True
        await session.commit()
    value, _ = await load_settings(session)
    return public_settings(value, revision)


async def configured(session, require_model=True):
    settings, _ = await load_settings(session)
    if not settings.enabled:
        raise HTTPException(409, "智能体已关闭，不会发出模型请求")
    if require_model and not settings.model.strip():
        raise HTTPException(409, "请先选择模型 ID")
    return settings


@router.get("/models")
async def list_models(session: AsyncSession = Depends(get_session)):
    try:
        return {
            "models": await ModelClient(
                await configured(session, require_model=False)
            ).models()
        }
    except (ModelError, ValueError) as exc:
        raise HTTPException(502, str(exc)) from None


@router.post("/test")
async def test_model(session: AsyncSession = Depends(get_session)):
    try:
        client = ModelClient(await configured(session))
        result, usage = await client.turn(
            [
                {
                    "role": "system",
                    "content": "Call the probe tool with ok=true. Do not output prose.",
                },
                {"role": "user", "content": "Test structured tool calling."},
            ],
            [
                tool_spec(
                    "probe",
                    "Connection capability test",
                    object_schema({"ok": {"type": "boolean"}}),
                )
            ],
        )
        valid = any(
            c["name"] == "probe" and c["arguments"].get("ok") is True
            for c in result.get("calls", [])
        )
        if not valid:
            raise HTTPException(422, "服务可连接，但模型未通过工具调用测试")
        return {
            "message": "连接与工具调用测试通过；图片输入需选择支持视觉的模型后开启",
            "tokens": usage,
        }
    except (ModelError, ValueError) as exc:
        raise HTTPException(502, str(exc)) from None


def job_out(job):
    return {
        "id": job.id,
        "kind": job.kind,
        "status": job.status,
        "calls": job.calls,
        "tokens": job.tokens,
        "message": job.message,
        "created_at": str(job.created_at),
        "finished_at": str(job.finished_at) if job.finished_at else None,
    }


async def create_job(body, actor_id, session):
    await configured(session)
    with process_lock(
        Path(load_config().data_path) / ".agent-jobs.lock", blocking=False
    ) as acquired:
        if not acquired:
            raise HTTPException(409, "智能体任务正在提交")
        active = (
            await session.execute(
                select(AgentJob.id).where(AgentJob.status.in_(["pending", "running"]))
            )
        ).first()
        if active:
            raise HTTPException(409, "已有智能体任务运行，请等待或取消")
        job = AgentJob(
            kind=body.kind,
            actor_id=actor_id,
            request=body.model_dump(),
            status="pending",
        )
        session.add(job)
        await session.commit()
        await session.refresh(job)
        launch(job.id)
        return job_out(job)


@router.post("/jobs")
async def start_job(
    body: AgentRequest,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    return await create_job(body, user.id, session)


@router.get("/jobs")
async def list_jobs(
    session: AsyncSession = Depends(get_session), offset: int = Query(0, ge=0)
):
    jobs = (
        await session.execute(
            select(AgentJob).order_by(AgentJob.id.desc()).offset(offset).limit(30)
        )
    ).scalars()
    return [job_out(j) for j in jobs]


@router.get("/jobs/{job_id}")
async def job_detail(
    job_id: int,
    offset: int = Query(0, ge=0),
    review_only: bool = False,
    session: AsyncSession = Depends(get_session),
):
    job = await session.get(AgentJob, job_id)
    if job is None:
        raise HTTPException(404, "任务不存在")
    query = select(AgentResult).where(AgentResult.job_id == job_id)
    if review_only:
        query = query.where(AgentResult.status.in_(REVIEW_STATUSES))
    rows = (
        await session.execute(query.order_by(AgentResult.id).offset(offset).limit(100))
    ).scalars()
    counts = dict(
        (
            await session.execute(
                select(AgentResult.status, func.count())
                .where(AgentResult.job_id == job_id)
                .group_by(AgentResult.status)
            )
        ).all()
    )
    return {
        **job_out(job),
        "counts": counts,
        "results": [
            {
                "id": r.id,
                "key": r.key,
                "status": r.status,
                "summary": r.summary,
                "data": r.data,
            }
            for r in rows
        ],
    }


@router.post("/jobs/{job_id}/cancel")
async def cancel_job(job_id: int, session: AsyncSession = Depends(get_session)):
    job = await session.get(AgentJob, job_id)
    if job is None:
        raise HTTPException(404, "任务不存在")
    job.cancel_requested = True
    await session.commit()
    return {"message": "已请求取消，停止后续调用并保留已完成结果"}


@router.post("/jobs/{job_id}/retry")
async def retry_job(
    job_id: int,
    user: User = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    job = await session.get(AgentJob, job_id)
    if job is None:
        raise HTTPException(404, "任务不存在")
    if job.status in {"pending", "running"}:
        raise HTTPException(409, "请等待当前任务停止")
    body = AgentRequest.model_validate(job.request)
    # Reuse completed fingerprints; failed items have no successful cache entry.
    body.retry = False
    return await create_job(body, user.id, session)


@router.post("/results/{result_id}/ignore")
async def ignore_result(result_id: int, session: AsyncSession = Depends(get_session)):
    result = await session.get(AgentResult, result_id)
    if result is None:
        raise HTTPException(404, "结果不存在")
    result.status = "ignored"
    await session.commit()
    return {"message": "已忽略，不修改游戏或补丁"}


@router.post("/results/ignore")
async def ignore_results(
    body: IgnoreResults, session: AsyncSession = Depends(get_session)
):
    rows = (
        await session.execute(
            select(AgentResult).where(
                AgentResult.id.in_(body.ids),
                AgentResult.status.in_(REVIEW_STATUSES),
            )
        )
    ).scalars()
    for result in rows:
        result.status = "ignored"
    await session.commit()
    return {"message": "已批量忽略，不修改游戏或补丁"}


async def interrupt_jobs():
    import database

    async with database._session_factory() as session:
        for job in (
            await session.execute(
                select(AgentJob).where(AgentJob.status.in_(["pending", "running"]))
            )
        ).scalars():
            job.status = "interrupted"
            job.message = "服务重启，任务已中断；可重试未完成内容"
            job.finished_at = datetime.utcnow()
        await session.commit()
