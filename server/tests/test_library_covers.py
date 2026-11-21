import tempfile
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

import httpx
from fastapi import FastAPI
from PIL import Image

from api import files, games
from api.auth import get_current_user
from config import Config
from models.game import Game
from models.user import User


class LibraryCoverTests(unittest.IsolatedAsyncioTestCase):
    async def test_same_name_replacement_changes_revision_and_serves_actual_image_type(
        self,
    ):
        app = FastAPI()
        app.include_router(files.router)
        app.dependency_overrides[get_current_user] = lambda: User(
            role="user", status="active"
        )
        with tempfile.TemporaryDirectory() as temp:
            config = Config(data_path=temp)
            path = config.covers_path / "sample.jpg"
            game = Game(
                id=1,
                name="Test",
                folder_path="test",
                cover_path=str(path),
                imported_at=datetime.now(timezone.utc),
            )
            with (
                patch.object(files, "load_config", return_value=config),
                patch.object(games, "load_config", return_value=config),
            ):
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                ) as client:
                    self.assertIsNone(
                        (await games._summaries([game]))[0].cover_revision
                    )
                    first = None
                    for fmt, mime in [("WEBP", "image/webp"), ("PNG", "image/png")]:
                        Image.new("RGB", (12, 16), "red").save(path, format=fmt)
                        summary = (await games._summaries([game]))[0]
                        self.assertIsNotNone(summary.cover_revision)
                        self.assertNotEqual(first, summary.cover_revision)
                        first = summary.cover_revision
                        result = await client.get(
                            "/api/files/covers/sample.jpg", params={"t": first}
                        )
                        self.assertEqual(result.status_code, 200)
                        self.assertEqual(result.headers["content-type"], mime)
                        self.assertEqual(result.content, path.read_bytes())
