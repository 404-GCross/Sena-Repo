import hashlib
import io
import os
import tempfile
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from unittest.mock import AsyncMock, patch

import bcrypt
import httpx
from fastapi import FastAPI, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
from api import auth, download, setup, steam_patch
from cli import users
from cli.common import CliError
from database import Base, get_session
from models.user import PASSWORD_SCHEME, User, UserOAuthBinding, UserSession, hash_password, verify_password


class PasswordPrimitiveTests(unittest.TestCase):
    def setUp(self):
        original = bcrypt.gensalt
        self.cost = patch.object(bcrypt, "gensalt", side_effect=lambda: original(rounds=4))
        self.cost.start()
        self.addCleanup(self.cost.stop)

    def test_long_unicode_passwords_preserve_the_entire_password(self):
        for password in ("a" * 73, "密" * 25, "😀" * 128, " " * 4):
            with self.subTest(length=len(password)):
                hashed, scheme = hash_password(password)
                self.assertEqual(scheme, PASSWORD_SCHEME)
                self.assertTrue(verify_password(password, scheme, hashed))
                self.assertFalse(verify_password(password[:-1] + "z", scheme, hashed))

    def test_legacy_bcrypt_keeps_historical_byte_truncation(self):
        password = "a" * 71 + "密后缀"
        hashed = bcrypt.hashpw(password.encode()[:72], bcrypt.gensalt()).decode()
        self.assertTrue(verify_password(password, "bcrypt", hashed))
        self.assertTrue(verify_password("a" * 71 + "密其他", "bcrypt", hashed))
        self.assertFalse(verify_password("b" + password[1:], "bcrypt", hashed))

    def test_legacy_sha_and_malformed_hashes_are_safe(self):
        salt = "legacy-test-salt"
        hashed = hashlib.sha256((salt + "legacy-password").encode()).hexdigest()
        self.assertTrue(verify_password("legacy-password", salt, hashed))
        self.assertFalse(verify_password("wrong-password", salt, hashed))
        for scheme, value in ((PASSWORD_SCHEME, "broken"), ("bcrypt", "密"), ("bcrypt-future", hashed), (salt, "X" * 64)):
            self.assertFalse(verify_password("password", scheme, value))
        for value in ("a" * 4097, "密" * 1366, "\ud800", None):
            self.assertFalse(verify_password(value, salt, hashed))

    def test_new_password_policy_matches_api_setup_and_cli(self):
        for password in ("a" * 73, "密" * 128):
            self.assertEqual(auth.CreateUserRequest(username="tester", password=password).password, password)
            self.assertEqual(auth.AdminUserUpdate(password=password).password, password)
            self.assertEqual(auth.ProfileUpdate(new_password=password).new_password, password)
            self.assertEqual(setup.InitRequest(admin_username="tester", admin_password=password).admin_password, password)
            args = SimpleNamespace(password=password, password_stdin=False)
            self.assertEqual(users._read_password(args), password)
        for password in ("abc", "x" * 129, "\ud800" * 4):
            for create in (
                lambda: auth.CreateUserRequest(username="tester", password=password),
                lambda: auth.AdminUserUpdate(password=password),
                lambda: auth.ProfileUpdate(new_password=password),
                lambda: setup.InitRequest(admin_username="tester", admin_password=password),
            ):
                with self.assertRaises(HTTPException) as result:
                    create()
                self.assertEqual(result.exception.status_code, 400)
                self.assertNotIn(password, str(result.exception.detail))
            with self.assertRaises(CliError):
                users._read_password(SimpleNamespace(password=password, password_stdin=False))
        self.assertEqual(auth.AdminUserUpdate(password="").password, "")
        self.assertIsNone(auth.CreateUserRequest(username="tester", nextmoe_user_id=1).password)
        with patch.object(users.sys, "stdin", io.StringIO("x" * 100000 + "\n")):
            with self.assertRaises(CliError):
                users._read_password(SimpleNamespace(password=None, password_stdin=True))


class PasswordAndSignedDownloadTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sena-auth-regression-")
        self.root = Path(self.temp.name).resolve()
        self.file = self.root / "fixture.zip"
        self.file.write_bytes(b"fixture archive bytes")
        original = bcrypt.gensalt
        self.patches = [
            patch.object(bcrypt, "gensalt", side_effect=lambda: original(rounds=4)),
            patch.object(config, "_cached_config", config.Config(data_path=str(self.root))),
            patch.object(download, "_signature_secret", return_value=b"isolated-test-signing-key"),
            patch.object(download, "_is_allowed_local_file", new=AsyncMock(return_value=True)),
            patch.object(download, "_manager_install_checksum", new=AsyncMock(return_value=None)),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        auth._login_failures.clear()
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.engine.begin() as connection:
            await connection.run_sync(lambda c: Base.metadata.create_all(c, tables=[User.__table__, UserOAuthBinding.__table__, UserSession.__table__]))
        async with self.sessions() as session:
            hashed, salt = hash_password("old-password")
            admin = User(username="fixture-admin", password_hash=hashed, salt=salt, role="admin", is_admin=True, status="active")
            user = User(username="fixture-user", password_hash=hashed, salt=salt, role="user", status="active")
            session.add_all([admin, user])
            await session.flush()
            self.admin_id, self.user_id = admin.id, user.id
            self.admin_token = await auth._issue_session_token(admin, session)
            self.token_a = await auth._issue_session_token(user, session)
            self.token_b = await auth._issue_session_token(user, session)
            await session.commit()
        self.game = SimpleNamespace(id=7, name="Fixture", company=None, developer=None, vndb_id=None, bangumi_id=None, steam_id=None, hikarinagi_id=None)
        self.version = SimpleNamespace(id=11, file_path=str(self.file), filename="fixture.zip", file_size=self.file.stat().st_size, source_type="local", extract_password=None, checksum_algo=None, checksum=None)
        resource = patch.object(download, "_get_game_and_version", new=AsyncMock(return_value=(self.game, self.version)))
        resource.start()
        self.addCleanup(resource.stop)
        self.app = FastAPI()
        self.app.include_router(auth.router)
        self.app.include_router(steam_patch.signed_router)
        self.app.include_router(download.router)
        self.app.include_router(steam_patch.router)
        self.app.include_router(setup.router)

        async def session_dependency():
            async with self.sessions() as session:
                yield session

        self.app.dependency_overrides[get_session] = session_dependency
        self.api = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://testserver")

    async def asyncTearDown(self):
        await self.api.aclose()
        await self.engine.dispose()
        auth._login_failures.clear()
        self.assertEqual(self.root, Path(self.temp.name).resolve())
        self.temp.cleanup()

    @staticmethod
    def headers(token):
        return {"Authorization": f"Bearer {token}"}

    async def mint(self, token=None):
        response = await self.api.post("/api/download/7/11/link", headers=self.headers(token or self.token_a))
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["url"]

    @staticmethod
    def alter(url, **changes):
        parts = urlsplit(url)
        query = {key: value[0] for key, value in parse_qs(parts.query).items()}
        for key, value in changes.items():
            if value is None:
                query.pop(key, None)
            else:
                query[key] = str(value)
        return urlunsplit(parts._replace(query=urlencode(query)))

    async def test_oversized_passwords_count_as_failed_logins(self):
        for index in range(5):
            response = await self.api.post("/api/auth/login", json={"username": "fixture-user", "password": "密" * 5000})
            self.assertEqual(response.status_code, 401 if index < 4 else 429)
        self.assertIn("retry-after", response.headers)

    async def test_login_does_not_rewrite_legacy_or_current_passwords(self):
        for legacy in (False, True):
            async with self.sessions() as session:
                user = await session.get(User, self.user_id)
                if legacy:
                    user.salt = "legacy-salt"
                    user.password_hash = hashlib.sha256(b"legacy-saltold-password").hexdigest()
                    await session.commit()
                previous = (user.password_hash, user.salt)
            response = await self.api.post("/api/auth/login", json={"username": "fixture-user", "password": "old-password"})
            self.assertEqual(response.status_code, 200)
            async with self.sessions() as session:
                user = await session.get(User, self.user_id)
                self.assertEqual((user.password_hash, user.salt), previous)

    async def test_password_creation_and_change_accept_long_unicode(self):
        password = "密" * 128
        response = await self.api.post("/api/auth/users", headers=self.headers(self.admin_token), json={"username": "long-password-user", "password": password})
        self.assertEqual(response.status_code, 200, response.text)
        response = await self.api.post("/api/auth/login", json={"username": "long-password-user", "password": password})
        self.assertEqual(response.status_code, 200)
        invalid = "sentinel" * 40
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.headers(self.admin_token), json={"password": invalid})
        self.assertEqual(response.status_code, 400)
        self.assertNotIn(invalid, response.text)

    async def test_signed_links_reject_tampering_legacy_and_malformed_signatures(self):
        url = await self.mint()
        self.assertEqual((await self.api.get(url)).status_code, 200)
        query = parse_qs(urlsplit(url).query)
        self.assertIn("sid", query)
        self.assertNotIn(self.token_a, url)
        self.assertNotIn(auth._token_hash(self.token_a), url)
        for changes in ({"uid": self.admin_id}, {"sid": 0}, {"sid": 2**65}, {"sid": None}, {"expires_at": int(time.time()) - 1}, {"signature": "密" * 64}, {"signature": "a" * 63}):
            self.assertEqual((await self.api.get(self.alter(url, **changes))).status_code, 403)
        self.assertEqual((await self.api.get(url.replace("/7/11?", "/7/12?"))).status_code, 403)
        self.assertEqual((await self.api.post("/api/download/7/11/link")).status_code, 401)

    async def test_logout_revokes_only_the_issuing_session(self):
        first, other = await self.mint(self.token_a), await self.mint(self.token_b)
        response = await self.api.post("/api/auth/logout", headers=self.headers(self.token_a))
        self.assertEqual(response.status_code, 200)
        self.assertEqual((await self.api.get(first)).status_code, 403)
        self.assertEqual((await self.api.get(other)).status_code, 200)

    async def test_disabled_deleted_and_expired_owners_fail_closed(self):
        url = await self.mint()
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.status = "rejected"
            await session.commit()
        self.assertEqual((await self.api.get(url)).status_code, 403)
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.status = "active"
            record = (await session.execute(select(UserSession).where(UserSession.token_hash == auth._token_hash(self.token_a)))).scalar_one()
            record.expires_at = datetime.utcnow() - timedelta(seconds=1)
            await session.commit()
        self.assertEqual((await self.api.get(url)).status_code, 403)
        other = await self.mint(self.token_b)
        response = await self.api.delete(f"/api/auth/users/{self.user_id}", headers=self.headers(self.admin_token))
        self.assertEqual(response.status_code, 200)
        self.assertEqual((await self.api.get(other)).status_code, 403)

    async def test_reused_session_id_cannot_revive_a_link(self):
        url = await self.mint()
        sid = int(parse_qs(urlsplit(url).query)["sid"][0])
        async with self.sessions() as session:
            await session.execute(delete(UserSession).where(UserSession.id == sid))
            session.add(UserSession(id=sid, user_id=self.user_id, token_hash=auth._token_hash("replacement-session"), expires_at=datetime.utcnow() + timedelta(days=1)))
            await session.commit()
        self.assertEqual((await self.api.get(url)).status_code, 403)

    async def test_self_password_rotation_revokes_previous_links(self):
        first, other = await self.mint(self.token_a), await self.mint(self.token_b)
        response = await self.api.put(f"/api/auth/profile/{self.user_id}", headers=self.headers(self.token_a), json={"current_password": "old-password", "new_password": "密" * 100})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual((await self.api.get(first)).status_code, 403)
        self.assertEqual((await self.api.get(other)).status_code, 403)
        login = await self.api.post("/api/auth/login", json={"username": "fixture-user", "password": "密" * 100})
        self.assertEqual(login.status_code, 200)
        self.assertEqual((await self.api.get(await self.mint(login.json()["token"])) ).status_code, 200)

    async def test_manager_urls_and_patch_urls_share_session_revocation(self):
        urls = []
        for target in ("lunabox", "reinamanager"):
            response = await self.api.post("/api/download/7/11/manager-install-link", headers=self.headers(self.token_a), json={"target": target})
            self.assertEqual(response.status_code, 200, response.text)
            urls.append(parse_qs(urlsplit(response.json()["install_url"]).query)["url"][0])
        with patch.object(steam_patch, "_find_patch_entry", return_value={"size": 42}), patch.object(steam_patch, "serve_patch_file", new=AsyncMock(return_value={"fixture": True})):
            response = await self.api.post("/api/steam/patches/123/link", headers=self.headers(self.token_a))
            self.assertEqual(response.status_code, 200, response.text)
            urls.append(response.json()["url"])
            for url in urls:
                self.assertEqual((await self.api.get(url)).status_code, 200)
            await self.api.post("/api/auth/logout", headers=self.headers(self.token_a))
            for url in urls:
                self.assertEqual((await self.api.get(url)).status_code, 403)

    async def test_openlist_direct_redirect_is_preserved_but_sena_link_revokes(self):
        self.version.source_type = "openlist"
        url = await self.mint()
        with patch.object(download, "_openlist_download_url", new=AsyncMock(return_value="https://files.invalid/fixture.zip")):
            response = await self.api.get(url)
            self.assertEqual(response.status_code, 302)
            self.assertEqual(response.headers["location"], "https://files.invalid/fixture.zip")
            await self.api.post("/api/auth/logout", headers=self.headers(self.token_a))
            self.assertEqual((await self.api.get(url)).status_code, 403)


if __name__ == "__main__":
    unittest.main()
