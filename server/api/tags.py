"""Tag management API."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.auth import get_current_user
from database import get_session
from models.user import User
from models.game import Game, GameTag
from models.tag import Tag
from schemas.common import MessageResponse
from schemas.tag import TagCreate, TagOut, TagUpdate

router = APIRouter(prefix="/api", tags=["tags"])


@router.get("/tags", response_model=list[TagOut])
async def list_tags(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """List all tags."""
    result = await session.execute(select(Tag).order_by(Tag.name))
    return result.scalars().all()


@router.post("/tags", response_model=TagOut, status_code=201)
async def create_tag(
    user: User = Depends(get_current_user),
    body: TagCreate,
    session: AsyncSession = Depends(get_session),
):
    """Create a new tag."""
    existing = await session.execute(
        select(Tag).where(Tag.name == body.name)
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Tag already exists")

    tag = Tag(name=body.name, color=body.color)
    session.add(tag)
    await session.commit()
    await session.refresh(tag)
    return tag


@router.put("/tags/{tag_id}", response_model=TagOut)
async def update_tag(
    user: User = Depends(get_current_user),
    tag_id: int,
    body: TagUpdate,
    session: AsyncSession = Depends(get_session),
):
    """Update a tag's name or color."""
    result = await session.execute(select(Tag).where(Tag.id == tag_id))
    tag = result.scalar_one_or_none()
    if tag is None:
        raise HTTPException(status_code=404, detail="Tag not found")

    if body.name is not None:
        # Check uniqueness
        dup = await session.execute(
            select(Tag).where(Tag.name == body.name, Tag.id != tag_id)
        )
        if dup.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="Tag name already exists")
        tag.name = body.name
    if body.color is not None:
        tag.color = body.color

    await session.commit()
    await session.refresh(tag)
    return tag


@router.delete("/tags/{tag_id}", response_model=MessageResponse)
async def delete_tag(
    user: User = Depends(get_current_user),
    tag_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Delete a tag (removes from all games)."""
    result = await session.execute(select(Tag).where(Tag.id == tag_id))
    tag = result.scalar_one_or_none()
    if tag is None:
        raise HTTPException(status_code=404, detail="Tag not found")

    await session.delete(tag)
    await session.commit()
    return MessageResponse(message=f"Tag '{tag.name}' deleted")


# Game-Tag association endpoints
@router.post("/games/{game_id}/tags/{tag_name}", response_model=MessageResponse)
async def add_tag_to_game(
    user: User = Depends(get_current_user),
    game_id: int,
    tag_name: str,
    session: AsyncSession = Depends(get_session),
):
    """Add a tag to a game by tag name. Creates the tag if it doesn't exist."""
    # Verify game exists
    game = await session.execute(select(Game).where(Game.id == game_id))
    if game.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Game not found")

    # Get or create tag
    tag_result = await session.execute(select(Tag).where(Tag.name == tag_name))
    tag = tag_result.scalar_one_or_none()
    if tag is None:
        tag = Tag(name=tag_name)
        session.add(tag)
        await session.flush()

    # Check existing association
    assoc = await session.execute(
        select(GameTag).where(GameTag.game_id == game_id, GameTag.tag_id == tag.id)
    )
    if assoc.scalar_one_or_none() is None:
        session.add(GameTag(game_id=game_id, tag_id=tag.id))
        await session.commit()

    return MessageResponse(message=f"Tag '{tag.name}' added to game")


@router.delete("/games/{game_id}/tags/{tag_id}", response_model=MessageResponse)
async def remove_tag_from_game(
    user: User = Depends(get_current_user),
    game_id: int,
    tag_id: int,
    session: AsyncSession = Depends(get_session),
):
    """Remove a tag from a game."""
    result = await session.execute(
        select(GameTag).where(GameTag.game_id == game_id, GameTag.tag_id == tag_id)
    )
    assoc = result.scalar_one_or_none()
    if assoc is None:
        raise HTTPException(status_code=404, detail="Tag not associated with this game")

    await session.delete(assoc)
    await session.commit()
    return MessageResponse(message="Tag removed from game")
