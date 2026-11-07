import base64
import hashlib
import json
import logging
import os
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
from api import auth, oauth
from api.auth import _issue_session_token
from database import Base, get_session
from models.user import User, UserOAuthBinding, UserSession
from services.oauth_providers import provider
from utils.secrets import decrypt_secret


class OAuthIdentityTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.signing_key = rsa.generate_private_key(65537, 2048)
        cls.other_key = rsa.generate_private_key(65537, 2048)

    async def asyncSetUp(self):
        self.config_patch = patch.object(config, "_cached_config", config.Config())
        self.config_patch.start()
        self.addCleanup(self.config_patch.stop)
        self.env_patch = patch.dict(
            os.environ, {"SENA_ENCRYPTION_KEY": Fernet.generate_key().decode()}
        )
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        oauth._flows.clear()
        oauth._attempts.clear()
        self.spec = provider("hikarinagi")
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.engine.begin() as conn:
            await conn.run_sync(
                lambda c: Base.metadata.create_all(
                    c, tables=[User.__table__, UserOAuthBinding.__table__, UserSession.__table__]
                )
            )
            await conn.execute(text("CREATE UNIQUE INDEX uq_user_oauth_bindings_provider_user_id ON user_oauth_bindings (provider, oauth_user_id) WHERE oauth_user_id IS NOT NULL"))
        async with self.sessions() as session:
            user = User(
                username="test-admin", password_hash="unused", salt="unused",
                role="admin", is_admin=True, status="active", password_set=True,
            )
            session.add(user)
            await session.flush()
            self.user_id = user.id
            token = await _issue_session_token(user, session)
            await session.commit()
        self.auth = {"Authorization": f"Bearer {token}"}
        self.app = FastAPI()
        self.app.include_router(oauth.router)
        self.app.include_router(auth.router)

        async def session_dependency():
            async with self.sessions() as session:
                yield session

        self.app.dependency_overrides[get_session] = session_dependency
        self.api = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app), base_url="http://testserver"
        )
        self.requests = []
        self.claim_overrides = {}
        self.omit_claims = set()
        self.header_overrides = {}
        self.algorithm = "RS256"
        self.signer = self.signing_key
        self.missing_id_token = False
        self.jwks_status = 200
        self.jwks_body = None
        self.jwks = {"keys": [self.public_jwk(self.signing_key, "test-key")]}
        self.nonce = ""
        self.profile_status = 200
        self.profile_body = {"id": 456, "nickname": "Test nickname"}
        self.id_token = ""
        self.catalog_access = jwt.encode(
            {"sub": "catalog-subject", "aud": "open-api", "exp": int(time.time()) + 3600},
            self.signing_key, algorithm="RS256", headers={"kid": "test-key"},
        )
        self.refresh_token = "test-refresh-token"
        self.http_patch = patch.object(
            oauth, "_http_client_kwargs",
            return_value={"transport": httpx.MockTransport(self.upstream), "timeout": 2},
        )
        self.http_patch.start()
        self.addCleanup(self.http_patch.stop)

    async def asyncTearDown(self):
        await self.api.aclose()
        await self.engine.dispose()
        oauth._flows.clear()
        oauth._attempts.clear()

    @staticmethod
    def public_jwk(key, kid):
        jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
        return {**jwk, "kid": kid, "alg": "RS256", "use": "sig"}

    def upstream(self, request):
        self.requests.append((request.method, request.url.path))
        if request.url.path == "/v3/user/me":
            self.assertEqual(str(request.url), "https://api.hikarinagi.org/v3/user/me")
            self.assertEqual(request.headers["authorization"], f"Bearer {self.catalog_access}")
            return httpx.Response(self.profile_status, json=self.profile_body)
        if request.url.path == "/oidc/token":
            form = parse_qs(request.content.decode())
            self.assertNotIn("authorization", request.headers)
            self.assertNotIn("client_secret", form)
            self.assertEqual(form["client_id"], [self.spec.client_id])
            self.assertEqual(form["redirect_uri"], [self.spec.redirect_uri])
            challenge = base64.urlsafe_b64encode(
                hashlib.sha256(form["code_verifier"][0].encode()).digest()
            ).rstrip(b"=").decode()
            self.assertEqual(challenge, self.challenge)
            claims = {
                "iss": self.spec.issuer, "aud": self.spec.client_id,
                "sub": "identity-subject", "name": "Test nickname",
                "iat": int(time.time()) - 5, "exp": int(time.time()) + 3600,
                "nonce": self.nonce, **self.claim_overrides,
            }
            for key in self.omit_claims:
                claims.pop(key, None)
            self.id_token = jwt.encode(
                claims, self.signer, algorithm=self.algorithm,
                headers={"kid": "test-key", **self.header_overrides},
            )
            tokens = {
                "access_token": self.catalog_access, "refresh_token": self.refresh_token,
                "expires_in": 3600, "scope": self.spec.scopes,
            }
            if not self.missing_id_token:
                tokens["id_token"] = self.id_token
            return httpx.Response(200, json=tokens)
        if request.url.path == "/oidc/jwks":
            self.assertNotIn("authorization", request.headers)
            if self.jwks_body is not None:
                return httpx.Response(self.jwks_status, content=self.jwks_body)
            return httpx.Response(self.jwks_status, json=self.jwks)
        if request.url.path == "/oidc/me":
            return httpx.Response(401, json={"error": "invalid_token"})
        if request.url.path == "/api/v1/oauth/token":
            return httpx.Response(200, json={"access_token": "nextmoe-token", "expires_in": 3600})
        if request.url.path == "/api/v1/oauth/userinfo":
            self.assertEqual(request.headers["authorization"], "Bearer nextmoe-token")
            return httpx.Response(200, json={"sub": "nextmoe-subject", "name": "NextMoe test", "id": 123})
        raise AssertionError("Unexpected upstream request")

    async def start(self, purpose="bind"):
        response = await self.api.post(
            "/api/auth/oauth/hikarinagi/start", json={"purpose": purpose},
            headers=self.auth if purpose == "bind" else {},
        )
        self.assertEqual(response.status_code, 200)
        flow = response.json()
        params = parse_qs(urlparse(flow["authorize_url"]).query)
        self.nonce = params["nonce"][0]
        self.challenge = params["code_challenge"][0]
        self.assertEqual(params["scope"][0], self.spec.scopes)
        self.assertEqual(params["prompt"], ["consent"])
        self.assertEqual(params["code_challenge_method"], ["S256"])
        return flow

    async def complete(self, flow, purpose="bind"):
        return await self.api.post(
            "/api/auth/oauth/hikarinagi/complete",
            json={"request_id": flow["request_id"], "state": flow["state"], "code": "test-code"},
            headers=self.auth if purpose == "bind" else {},
        )

    async def assert_no_binding(self):
        async with self.sessions() as session:
            self.assertEqual((await session.execute(select(func.count()).select_from(UserOAuthBinding))).scalar(), 0)
            self.assertEqual((await session.execute(select(func.count()).select_from(UserSession))).scalar(), 1)
        self.assertNotIn(("GET", "/oidc/me"), self.requests)

    async def test_catalog_access_binds_using_verified_identity(self):
        async with self.sessions() as session:
            session.add(UserOAuthBinding(user_id=self.user_id, provider="nextmoe", subject="nextmoe-subject"))
            await session.commit()
        first = await self.start()
        flow = await self.start()
        self.assertNotEqual(first["request_id"], flow["request_id"])
        self.assertNotEqual(oauth._flows[first["request_id"]].nonce, self.nonce)
        response = await self.complete(flow)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["name"], "Test nickname")
        self.assertNotIn("id_token", response.json())
        self.assertNotIn(self.catalog_access, response.text)
        async with self.sessions() as session:
            bindings = (await session.execute(select(UserOAuthBinding))).scalars().all()
            self.assertEqual(len(bindings), 2)
            binding = next(b for b in bindings if b.provider == "hikarinagi")
            self.assertEqual(binding.subject, "identity-subject")
            self.assertEqual(decrypt_secret(binding.access_token), self.catalog_access)
            self.assertEqual(decrypt_secret(binding.refresh_token), self.refresh_token)
            self.assertIn("catalog:full", binding.scope)
        self.assertNotIn(("GET", "/oidc/me"), self.requests)
        self.assertEqual((await self.complete(flow)).status_code, 400)

    async def test_existing_binding_logs_in(self):
        async with self.sessions() as session:
            session.add(UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", subject="identity-subject"))
            await session.commit()
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["id"], self.user_id)
        self.assertIn("token", response.json())
        self.assertNotIn(("GET", "/oidc/me"), self.requests)

    async def test_unbound_login_does_not_create_account(self):
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.status_code, 403)
        await self.assert_no_binding()
        async with self.sessions() as session:
            self.assertEqual((await session.execute(select(func.count()).select_from(User))).scalar(), 1)

    async def test_disabled_account_cannot_log_in(self):
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.status = "rejected"
            session.add(UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", subject="identity-subject"))
            await session.commit()
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.status_code, 403)
        async with self.sessions() as session:
            binding = (await session.execute(select(UserOAuthBinding))).scalar_one()
            self.assertIsNone(binding.access_token)

    async def test_setup_consumes_verified_identity_once(self):
        async with self.sessions() as session:
            await session.execute(delete(UserSession))
            await session.execute(delete(User))
            await session.commit()
        flow = await self.start("setup")
        response = await self.complete(flow, "setup")
        self.assertEqual(response.status_code, 200)
        binding = oauth.consume_setup_binding(flow["request_id"])
        self.assertEqual(binding["subject"], "identity-subject")
        self.assertEqual(binding["tokens"]["access_token"], self.catalog_access)
        self.assertIsNone(oauth.consume_setup_binding(flow["request_id"]))

    async def test_invalid_claims_never_bind(self):
        cases = [
            {"exp": int(time.time()) - 120}, {"iat": int(time.time()) + 120},
            {"nbf": int(time.time()) + 120}, {"iss": "https://wrong.example/oidc"},
            {"aud": "open-api"}, {"aud": [self.spec.client_id, "other-client"]},
            {"azp": "wrong-client"}, {"nonce": "wrong-flow"},
            {"nonce": 123}, {"sub": ""}, {"sub": 123}, {"at_hash": "wrong-hash"},
        ]
        for index, claims in enumerate(cases):
            with self.subTest(case=index):
                self.claim_overrides = claims
                flow = await self.start()
                response = await self.complete(flow)
                self.assertEqual(response.status_code, 400)
                self.assertNotIn(flow["request_id"], oauth._flows)
                await self.assert_no_binding()

    async def test_missing_claims_never_bind(self):
        for claim in ("iss", "aud", "sub", "exp", "iat", "nonce"):
            with self.subTest(claim=claim):
                self.omit_claims = {claim}
                response = await self.complete(await self.start())
                self.assertEqual(response.status_code, 400)
                await self.assert_no_binding()

    async def test_missing_id_token_has_no_userinfo_fallback(self):
        self.missing_id_token = True
        response = await self.complete(await self.start())
        self.assertEqual(response.status_code, 400)
        await self.assert_no_binding()

    async def test_wrong_signature_rejected_without_logging_tokens(self):
        self.signer = self.other_key
        flow = await self.start()
        with self.assertLogs("api.oauth", logging.WARNING) as captured:
            response = await self.complete(flow)
        self.assertEqual(response.status_code, 400)
        output = "\n".join(captured.output) + response.text
        for sensitive in (self.id_token, self.catalog_access, self.refresh_token, self.nonce):
            self.assertNotIn(sensitive, output)
        await self.assert_no_binding()

    async def test_unsigned_and_hmac_tokens_rejected(self):
        for algorithm, signer in (("none", None), ("HS256", "x" * 32)):
            with self.subTest(algorithm=algorithm):
                self.algorithm, self.signer = algorithm, signer
                self.assertEqual((await self.complete(await self.start())).status_code, 400)
                await self.assert_no_binding()

    async def test_unknown_or_disallowed_signing_key_rejected(self):
        original = self.public_jwk(self.signing_key, "test-key")
        cases = [[], [{**original, "kid": "other"}], [original, original],
                 [{**original, "use": "enc"}], [{**original, "key_ops": ["encrypt"]}]]
        for index, keys in enumerate(cases):
            with self.subTest(case=index):
                self.jwks = {"keys": keys}
                self.assertEqual((await self.complete(await self.start())).status_code, 400)
                await self.assert_no_binding()

    async def test_key_rotation_uses_current_jwks(self):
        self.signer = self.other_key
        self.header_overrides = {"kid": "rotated-key"}
        self.jwks = {"keys": [self.public_jwk(self.other_key, "rotated-key")]}
        self.assertEqual((await self.complete(await self.start())).status_code, 200)

    async def test_jwks_failure_is_distinct_from_invalid_identity(self):
        for status, body in ((503, b"unavailable"), (200, b"invalid JSON"), (200, b"[]")):
            with self.subTest(status=status, body=body):
                self.jwks_status, self.jwks_body = status, body
                self.assertEqual((await self.complete(await self.start())).status_code, 502)
                await self.assert_no_binding()

    async def test_access_hash_and_single_audience_array_are_accepted(self):
        digest = hashlib.sha256(self.catalog_access.encode()).digest()
        self.claim_overrides = {
            "at_hash": base64.urlsafe_b64encode(digest[:16]).rstrip(b"=").decode(),
            "aud": [self.spec.client_id], "azp": self.spec.client_id,
        }
        self.assertEqual((await self.complete(await self.start())).status_code, 200)

    async def test_nextmoe_keeps_legacy_userinfo_flow(self):
        response = await self.api.post(
            "/api/auth/oauth/start", json={"purpose": "bind", "redirect_port": 54321},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 200)
        flow = response.json()
        self.assertNotIn("nonce", parse_qs(urlparse(flow["authorize_url"]).query))
        response = await self.api.post(
            "/api/auth/oauth/complete",
            json={"request_id": flow["request_id"], "state": flow["state"], "code": "nextmoe-code"},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["user_id"], 123)
        self.assertEqual(response.json()["nextmoe_access_token"], "nextmoe-token")
        self.assertIn(("GET", "/api/v1/oauth/userinfo"), self.requests)
        self.assertNotIn(("GET", "/oidc/jwks"), self.requests)

    async def test_admin_preprovisioned_hikarinagi_first_login(self):
        created = await self.api.post("/api/auth/users", headers=self.auth, json={
            "username": "new-user", "hikarinagi_user_id": 456,
        })
        self.assertEqual(created.status_code, 200, created.text)
        user_id = created.json()["user_id"]
        async with self.sessions() as session:
            user = await session.get(User, user_id)
            self.assertFalse(user.password_set)
        for _ in range(2):
            response = await self.complete(await self.start("login"), "login")
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["id"], user_id)
        async with self.sessions() as session:
            binding = (await session.execute(select(UserOAuthBinding).where(UserOAuthBinding.user_id == user_id))).scalar_one()
            self.assertEqual(binding.subject, "identity-subject")
            self.assertEqual(binding.oauth_user_id, 456)

    async def test_create_validation_and_duplicate_id(self):
        for value in (0, -1, True, 1.5, "456", 9223372036854775808):
            response = await self.api.post("/api/auth/users", headers=self.auth, json={"username": "new-user", "hikarinagi_user_id": value})
            self.assertEqual(response.status_code, 422)
        response = await self.api.post("/api/auth/users", headers=self.auth, json={"username": "new-user"})
        self.assertEqual(response.status_code, 400)
        for username, expected in (("first", 200), ("second", 409)):
            response = await self.api.post("/api/auth/users", headers=self.auth, json={"username": username, "hikarinagi_user_id": 456})
            self.assertEqual(response.status_code, expected, response.text)

    async def test_profile_failure_never_binds(self):
        for status, body, expected in ((403, {}, 400), (401, {}, 400), (503, {}, 502), (200, [], 502), (200, {"id": True}, 502), (200, {"id": "456"}, 502)):
            self.profile_status, self.profile_body = status, body
            response = await self.complete(await self.start())
            self.assertEqual(response.status_code, expected, response.text)
            await self.assert_no_binding()

    async def test_subject_and_numeric_id_cannot_select_different_users(self):
        async with self.sessions() as session:
            other = User(username="other", password_hash="unused", salt="unused", role="user", status="active")
            session.add(other)
            await session.flush()
            session.add_all([
                UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", subject="identity-subject"),
                UserOAuthBinding(user_id=other.id, provider="hikarinagi", oauth_user_id=456),
            ])
            await session.commit()
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.status_code, 409)

    async def test_wrong_preassigned_id_cannot_be_overwritten_by_binding(self):
        async with self.sessions() as session:
            session.add(UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", oauth_user_id=999))
            await session.commit()
        response = await self.complete(await self.start())
        self.assertEqual(response.status_code, 409)

    async def test_admin_edit_preserves_clears_and_revokes_sessions(self):
        response = await self.complete(await self.start())
        self.assertEqual(response.status_code, 200)
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"hikarinagi_user_id": 456})
        self.assertEqual(response.status_code, 200)
        response = await self.api.get("/api/auth/users", headers=self.auth)
        self.assertTrue(response.json()[0]["oauth_bindings"][0]["bound"])
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"hikarinagi_user_id": 789, "clear_hikarinagi": True})
        self.assertEqual(response.status_code, 400)
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"clear_hikarinagi": True})
        self.assertEqual(response.status_code, 200)
        self.assertEqual((await self.api.get("/api/auth/users", headers=self.auth)).status_code, 401)
        async with self.sessions() as session:
            self.assertEqual((await session.execute(select(func.count()).select_from(UserOAuthBinding))).scalar(), 0)

    async def test_user_cannot_provision_accounts(self):
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.role = "user"
            user.is_admin = False
            await session.commit()
        response = await self.api.post("/api/auth/users", headers=self.auth, json={"username": "new-user", "hikarinagi_user_id": 456})
        self.assertEqual(response.status_code, 403)
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"hikarinagi_user_id": 456})
        self.assertEqual(response.status_code, 403)

    async def test_last_passwordless_admin_cannot_clear_only_binding(self):
        self.assertEqual((await self.complete(await self.start())).status_code, 200)
        async with self.sessions() as session:
            user = await session.get(User, self.user_id)
            user.password_set = False
            await session.commit()
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"clear_hikarinagi": True})
        self.assertEqual(response.status_code, 400)

    def test_legacy_provider_config_still_requests_public_profile(self):
        config._cached_config.oauth.providers["hikarinagi"] = config.OAuthProviderConfig(scopes="openid profile catalog:full", numeric_user_id=False)
        spec = provider("hikarinagi")
        self.assertIn("user:read", spec.scopes.split())
        self.assertTrue(spec.numeric_user_id)

    async def test_both_preassigned_providers_can_login(self):
        response = await self.api.post("/api/auth/users", headers=self.auth, json={
            "username": "dual-user", "hikarinagi_user_id": 456, "nextmoe_user_id": 123,
        })
        self.assertEqual(response.status_code, 200)
        target_id = response.json()["user_id"]
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.json()["id"], target_id)
        response = await self.api.post("/api/auth/oauth/start", json={"purpose": "login", "redirect_port": 54321})
        flow = response.json()
        response = await self.api.post("/api/auth/oauth/complete", json={
            "request_id": flow["request_id"], "state": flow["state"], "code": "nextmoe-code",
        })
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["id"], target_id)

    async def test_profile_timeout_never_binds(self):
        flow = await self.start()
        original = self.upstream

        def upstream(request):
            if request.url.path == "/v3/user/me":
                raise httpx.ReadTimeout("test timeout", request=request)
            return original(request)

        with patch.object(oauth, "_http_client_kwargs", return_value={"transport": httpx.MockTransport(upstream)}):
            response = await self.complete(flow)
        self.assertEqual(response.status_code, 502)
        await self.assert_no_binding()

    async def test_wrong_id_cannot_login_to_pending_account(self):
        async with self.sessions() as session:
            session.add(UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", oauth_user_id=999))
            await session.commit()
        response = await self.complete(await self.start("login"), "login")
        self.assertEqual(response.status_code, 403)
        async with self.sessions() as session:
            binding = (await session.execute(select(UserOAuthBinding))).scalar_one()
            self.assertIsNone(binding.subject)
            self.assertIsNone(binding.access_token)

    async def test_changed_id_clears_tokens_and_revokes_session(self):
        self.assertEqual((await self.complete(await self.start())).status_code, 200)
        response = await self.api.put(f"/api/auth/users/{self.user_id}", headers=self.auth, json={"hikarinagi_user_id": 789})
        self.assertEqual(response.status_code, 200)
        async with self.sessions() as session:
            binding = (await session.execute(select(UserOAuthBinding))).scalar_one()
            self.assertEqual(binding.oauth_user_id, 789)
            for name in ("subject", "name", "access_token", "refresh_token", "expires_at", "scope"):
                self.assertIsNone(getattr(binding, name))
        self.assertEqual((await self.api.get("/api/auth/users", headers=self.auth)).status_code, 401)

    async def test_pending_and_bound_ids_survive_backup_restore(self):
        from cli.backup import _export_accounts, _restore_user_bindings

        async with self.sessions() as session:
            session.add(UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", oauth_user_id=456))
            await session.commit()
        for bound in (False, True):
            if bound:
                self.assertEqual((await self.complete(await self.start())).status_code, 200)
            async with self.sessions() as session:
                exported = await _export_accounts(session)
                entry = exported["users"][0]
                self.assertEqual(entry["oauth_bindings"][0]["user_id"], 456)
                await session.execute(delete(UserOAuthBinding))
                await session.flush()
                user = await session.get(User, self.user_id)
                await _restore_user_bindings(session, user, entry, {"users_skipped": 0}, [])
                await session.commit()
                binding = (await session.execute(select(UserOAuthBinding))).scalar_one()
                self.assertEqual(binding.oauth_user_id, 456)
                self.assertEqual(bool(binding.subject), bound)

    async def test_database_rejects_duplicate_provider_id(self):
        from sqlalchemy.exc import IntegrityError

        async with self.sessions() as session:
            other = User(username="other", password_hash="unused", salt="unused", role="user", status="active")
            session.add(other)
            await session.flush()
            session.add_all([
                UserOAuthBinding(user_id=self.user_id, provider="hikarinagi", oauth_user_id=456),
                UserOAuthBinding(user_id=other.id, provider="hikarinagi", oauth_user_id=456),
            ])
            with self.assertRaises(IntegrityError):
                await session.flush()
            await session.rollback()
