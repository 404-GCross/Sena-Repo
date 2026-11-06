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
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import config
from api import oauth
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
