from __future__ import annotations

import base64
import hashlib
import secrets

import httpx
import jwt

from services.oauth_providers import OAuthProvider


class OIDCKeySetError(RuntimeError):
    pass


async def verify_id_token(
    spec: OAuthProvider,
    tokens: dict,
    nonce: str,
    *,
    http_client_kwargs: dict,
) -> dict:
    token = tokens.get("id_token")
    if not isinstance(token, str) or not token or len(token) > 65536:
        raise jwt.InvalidTokenError("Missing or invalid ID token")
    if not nonce:
        raise jwt.InvalidTokenError("Missing flow nonce")
    header = jwt.get_unverified_header(token)
    kid = header.get("kid")
    if header.get("alg") != "RS256" or header.get("crit"):
        raise jwt.InvalidAlgorithmError("Unsupported ID token algorithm")
    if not isinstance(kid, str) or not kid:
        raise jwt.InvalidTokenError("Missing signing key identifier")

    # Use the configured issuer, never jku/x5u URLs supplied by the token.
    jwks_url = f"{spec.issuer.rstrip('/')}/jwks"
    try:
        async with httpx.AsyncClient(**http_client_kwargs) as client:
            response = await client.get(
                jwks_url, headers={"Accept": "application/json"}
            )
            response.raise_for_status()
        data = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise OIDCKeySetError("Unable to read signing keys") from exc
    if not isinstance(data, dict) or not isinstance(data.get("keys"), list):
        raise OIDCKeySetError("Invalid signing key set")
    keys = [
        key for key in data["keys"]
        if isinstance(key, dict)
        and key.get("kid") == kid
        and key.get("kty") == "RSA"
        and key.get("alg", "RS256") == "RS256"
        and key.get("use", "sig") == "sig"
        and isinstance(key.get("key_ops", ["verify"]), list)
        and "verify" in key.get("key_ops", ["verify"])
    ]
    if len(keys) != 1:
        raise jwt.InvalidTokenError("Signing key not found or ambiguous")
    try:
        key = jwt.PyJWK.from_dict(keys[0], algorithm="RS256").key
    except (jwt.PyJWTError, ValueError, TypeError, KeyError) as exc:
        raise OIDCKeySetError("Invalid signing key") from exc
    claims = jwt.decode(
        token,
        key,
        algorithms=["RS256"],
        issuer=spec.issuer,
        audience=spec.client_id,
        leeway=30,
        options={"require": ["iss", "sub", "aud", "exp", "iat", "nonce"]},
    )
    if not isinstance(claims["sub"], str) or not claims["sub"].strip():
        raise jwt.InvalidTokenError("Empty subject")
    if claims["aud"] not in (spec.client_id, [spec.client_id]):
        raise jwt.InvalidAudienceError("Unexpected additional audience")
    if "azp" in claims and claims["azp"] != spec.client_id:
        raise jwt.InvalidAudienceError("Wrong authorized party")
    actual_nonce = claims["nonce"]
    if not isinstance(actual_nonce, str) or not secrets.compare_digest(
        actual_nonce.encode("utf-8"), nonce.encode("utf-8")
    ):
        raise jwt.InvalidTokenError("Nonce mismatch")
    if "at_hash" in claims:
        access = tokens.get("access_token")
        if not isinstance(access, str) or not access:
            raise jwt.InvalidTokenError("Missing access token")
        digest = hashlib.sha256(access.encode("ascii")).digest()
        expected_hash = base64.urlsafe_b64encode(digest[:16]).rstrip(b"=")
        actual_hash = claims["at_hash"]
        if not isinstance(actual_hash, str) or not secrets.compare_digest(
            actual_hash.encode("utf-8"), expected_hash
        ):
            raise jwt.InvalidTokenError("Access token hash mismatch")
    return claims
