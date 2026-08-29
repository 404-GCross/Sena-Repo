"""Hikarinagi OAuth binding API."""

from __future__ import annotations

import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import require_admin
from config import load_config, normalize_scraper_config
from database import get_session
from models.user import User
from services.hikarinagi_oauth import (
    account_status_payload,
    configured_redirect_uri,
    configured_scope,
    consume_pending_auth,
    create_authorization_url,
    exchange_authorization_code,
    get_active_account,
    revoke_active_accounts,
    save_authorized_account,
)

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/integrations/hikarinagi",
    tags=["hikarinagi-auth"],
)


class HikarinagiAuthCompleteRequest(BaseModel):
    code: str
    state: str


@router.get("/status")
async def hikarinagi_auth_status(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    del user
    account = await get_active_account(session)
    return account_status_payload(account)


@router.post("/auth/start")
async def start_hikarinagi_auth(
    user: User = Depends(require_admin),
):
    config = load_config()
    normalize_scraper_config(config.scrapers)
    client_id = config.scrapers.hikarinagi_client_id.strip()
    scope = configured_scope()
    redirect_uri = configured_redirect_uri()
    if not client_id:
        raise HTTPException(status_code=400, detail="项目尚未内置 Hikarinagi 应用 ID")

    authorization_url, state = create_authorization_url(
        user_id=user.id,
        client_id=client_id,
        scope=scope,
        redirect_uri=redirect_uri,
    )
    return {
        "authorization_url": authorization_url,
        "state": state,
        "redirect_uri": redirect_uri,
        "scope": scope,
    }


@router.post("/auth/complete")
async def complete_hikarinagi_auth(
    body: HikarinagiAuthCompleteRequest,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    code = body.code.strip()
    state = body.state.strip()
    if not code or not state:
        raise HTTPException(status_code=400, detail="Hikarinagi 回调缺少 code 或 state")

    try:
        pending = consume_pending_auth(state, user.id)
        config = load_config()
        client_kwargs = {"timeout": httpx.Timeout(20.0)}
        if config.proxy:
            client_kwargs["proxy"] = config.proxy
        async with httpx.AsyncClient(**client_kwargs) as client:
            token_payload = await exchange_authorization_code(
                client,
                client_id=str(pending["client_id"]),
                code=code,
                code_verifier=str(pending["code_verifier"]),
                redirect_uri=str(pending["redirect_uri"]),
            )
        account = await save_authorized_account(
            session,
            user_id=user.id,
            client_id=str(pending["client_id"]),
            scope=str(pending["scope"]),
            token_payload=token_payload,
        )
        return account_status_payload(account)
    except httpx.HTTPStatusError as exc:
        logger.warning(
            "Hikarinagi OAuth token exchange failed: status=%s",
            exc.response.status_code,
        )
        raise HTTPException(
            status_code=400,
            detail=f"Hikarinagi 授权失败: HTTP {exc.response.status_code}",
        ) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.delete("")
async def disconnect_hikarinagi(
    session: AsyncSession = Depends(get_session),
    user: User = Depends(require_admin),
):
    del user
    count = await revoke_active_accounts(session)
    return {"message": "已解除 Hikarinagi 绑定", "revoked": count}
