#!/usr/bin/env python3
"""Emergency CLI: reassign server owner.

Usage (inside container):
    docker exec -it sena-repo python set_owner.py <username>

Usage (direct):
    python set_owner.py <username>
"""
from __future__ import annotations
import asyncio, os, sys

sys.path.insert(0, os.path.dirname(__file__))


async def main(username: str) -> None:
    from config import load_config
    from database import init_database, create_tables
    from sqlalchemy import select
    from models.user import User
    import database as db

    config = load_config()
    init_database(config)
    await create_tables()

    async with db._session_factory() as session:
        # Find target user
        result = await session.execute(select(User).where(User.username == username))
        target = result.scalar_one_or_none()
        if target is None:
            print(f"Error: user '{username}' not found.")
            result = await session.execute(select(User.username, User.role))
            print("Existing users:")
            for row in result:
                print(f"  {row[0]}  ({row[1]})")
            return

        if target.role == "owner":
            print(f"'{username}' is already the server owner.")
            return

        # Demote current owner(s) to admin
        owners = await session.execute(select(User).where(User.role == "owner"))
        for owner in owners.scalars():
            owner.role = "admin"
            owner.is_admin = True
            print(f"Demoted '{owner.username}' from owner to admin.")

        # Set target as owner
        target.role = "owner"
        target.is_admin = True
        target.status = "active"
        await session.commit()
        print(f"Success: '{username}' is now the server owner.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python set_owner.py <username>")
        sys.exit(1)
    asyncio.run(main(sys.argv[1]))
