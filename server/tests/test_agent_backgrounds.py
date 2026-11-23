import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from PIL import Image
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
import database
from models.agent import AgentJob
from models.game import Game
from schemas.agent import AgentSettings
from services.agent.backgrounds import ranked_backgrounds
from services.agent.jobs import scrape_game
from services.agent.providers import ModelError
from services.scraper.base import ScraperResult
from services.scraper.nextmoe import _parse_work
from services.scraper.orchestrator import scrape_single_game


class AgentBackgroundTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.config = config.Config(data_path=tmp.name)
        self.engine = create_async_engine(self.config.database_url)
        self.addAsyncCleanup(self.engine.dispose)
        for target, field, val in ((config, '_cached_config', self.config), (database, '_engine', self.engine)):
            p = patch.object(target, field, val)
            p.start()
            self.addCleanup(p.stop)
        await database.create_tables()
        self.session = async_sessionmaker(self.engine, expire_on_commit=False)()
        self.addAsyncCleanup(self.session.close)
        self.game = Game(name='Game', folder_path=tmp.name, root_id=0, developer='Studio',
                         description='Game', cover_path='keep-cover.jpg')
        job = AgentJob(kind='scrape', request={})
        self.session.add_all([self.game, job])
        await self.session.commit()
        self.runtime = SimpleNamespace(job=job, session=self.session, settings=AgentSettings(update_mode='overwrite'),
                                       check=AsyncMock())
        self.art, self.shot = [f'https://images.example/{kind}' for kind in ('art', 'shot')]
        self.result = _parse_work(dict(id=1, display_name='Game', banner=self.art, screenshots=[self.shot]))
        self.source = SimpleNamespace(source_name='nextmoe', search_best=AsyncMock(return_value=self.result),
                                      close=AsyncMock())
        self.requests = []
        self.responses = {}
        for url, color in ((self.art, 'red'), (self.shot, 'blue')):
            buf = io.BytesIO()
            Image.new('RGB', (80, 45), color).save(buf, 'PNG')
            self.responses[url] = buf.getvalue()

        def serve(request):
            url = str(request.url)
            self.requests.append(url)
            return httpx.Response(200, content=self.responses[url])

        self.client = httpx.AsyncClient(transport=httpx.MockTransport(serve))
        self.addAsyncCleanup(self.client.aclose)
        for target in ('services.agent.images._is_public_http_url', 'services.scraper.orchestrator._is_public_http_url'):
            p = patch(target, new=AsyncMock(return_value=True))
            p.start()
            self.addCleanup(p.stop)

    async def run_agent(self, *, fallback=False):
        async def select(runtime, catalog, context):
            if fallback:
                raise ModelError('unavailable')
            catalog.selection = SimpleNamespace(platforms={})
            return self.result, 'Verified game'

        with patch('services.agent.metadata._build_scrapers', return_value=[self.source]), \
             patch('services.agent.jobs.select_metadata', side_effect=select):
            await scrape_game(self.runtime, self.game, self.client)

    async def test_switching_preference_changes_actual_image_without_vision(self):
        await self.run_agent()
        path = Path(self.game.bg_path)
        self.assertEqual(path.read_bytes(), self.responses[self.art])
        self.runtime.settings.background_preference = 'screenshot'
        await self.run_agent()
        self.assertEqual(path.read_bytes(), self.responses[self.shot])
        self.assertEqual(self.requests, [self.art, self.shot])

    async def test_only_agent_fallback_uses_preference(self):
        self.runtime.settings.background_preference = 'screenshot'
        await self.run_agent(fallback=True)
        path = Path(self.game.bg_path)
        self.assertEqual(path.read_bytes(), self.responses[self.shot])
        await scrape_single_game(self.game, [self.source], self.client, self.config.covers_path,
                                 self.session, self.config, mode='overwrite')
        self.assertEqual(path.read_bytes(), self.responses[self.art])
        self.assertEqual(self.requests, [self.shot, self.art])

    async def test_unusable_images_fall_back_without_damaging_existing_file(self):
        self.responses[self.art] = b'invalid image'
        await self.run_agent()
        self.assertEqual(self.requests, [self.art, self.shot])
        path = Path(self.game.bg_path)
        original = path.read_bytes()
        self.runtime.settings.background_preference = 'screenshot'
        self.responses[self.shot] = b'also invalid'
        await self.run_agent()
        self.assertEqual(self.requests, [self.art, self.shot, self.shot, self.art])
        self.assertEqual(path.read_bytes(), original)
        self.responses[self.shot] = original
        await self.run_agent()
        self.assertEqual(self.requests[-1], self.shot)

    async def test_missing_only_and_locked_rows_keep_background(self):
        self.runtime.settings.update_mode = 'missing'
        self.game.bg_path = 'manual.jpg'
        await self.session.commit()
        await self.run_agent(fallback=True)
        self.game.metadata_locked = True
        self.runtime.settings.update_mode = 'overwrite'
        await self.session.commit()
        await self.run_agent()
        self.assertEqual(self.game.bg_path, 'manual.jpg')
        self.assertEqual(self.requests, [])

    def test_linked_work_only_and_screenshot_alias_is_not_artwork(self):
        result = ScraperResult(source_name='vndb_kana', source_id='v1', hero_url=self.shot, screenshot_urls=[self.shot])
        self.result.external_ids = {'vndb': '1'}
        other = ScraperResult(source_name='vndb', source_id='v2', background_media=[('artwork', 'wrong')])
        urls = ranked_backgrounds('artwork', [result, other, self.result], selected=result)
        self.assertEqual(urls, [self.art, self.shot])
        self.assertEqual(ranked_backgrounds('artwork', [result]), [self.shot])
