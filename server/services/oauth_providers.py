"""OAuth provider metadata shared by login, binding, and scraper tokens."""

from __future__ import annotations

from dataclasses import dataclass

from config import OAuthProviderConfig, load_config

DEFAULT_REDIRECT_PATH = "/callback"
HIKARINAGI_REDIRECT_URI = "http://127.0.0.1:11453/callback"


@dataclass(frozen=True)
class OAuthProvider:
    key: str
    label: str
    enabled: bool
    issuer: str
    client_id: str
    scopes: str
    authorize_url: str
    token_url: str
    userinfo_url: str
    redirect_uri: str = ""
    prompt: str = ""
    numeric_user_id: bool = True


def _join(issuer: str, path: str) -> str:
    if path.startswith("http://") or path.startswith("https://"):
        return path
    return f"{issuer.rstrip('/')}/{path.lstrip('/')}"


def _defaults() -> dict[str, OAuthProviderConfig]:
    oauth = load_config().oauth
    return {
        "nextmoe": OAuthProviderConfig(
            enabled=oauth.enabled,
            name="NextMoe·未萌",
            issuer=oauth.issuer,
            client_id=oauth.client_id,
            scopes=oauth.scopes,
            authorize_path="oauth/authorize",
            token_path="oauth/token",
            userinfo_path="oauth/userinfo",
            numeric_user_id=True,
        ),
        "hikarinagi": OAuthProviderConfig(
            enabled=oauth.hikarinagi_enabled,
            name="Hikarinagi",
            issuer=oauth.hikarinagi_issuer,
            client_id=oauth.hikarinagi_client_id,
            scopes=oauth.hikarinagi_scopes,
            authorize_path="auth",
            token_path="token",
            userinfo_path="me",
            redirect_uri=HIKARINAGI_REDIRECT_URI,
            prompt="consent",
            numeric_user_id=True,
        ),
    }


def _merge(
    default: OAuthProviderConfig,
    override: OAuthProviderConfig | None,
) -> OAuthProviderConfig:
    if override is None:
        return default
    return OAuthProviderConfig(
        enabled=(
            override.enabled if override.enabled is not None else default.enabled
        ),
        name=override.name or default.name,
        issuer=override.issuer or default.issuer,
        client_id=override.client_id or default.client_id,
        scopes=override.scopes or default.scopes,
        authorize_path=override.authorize_path or default.authorize_path,
        token_path=override.token_path or default.token_path,
        userinfo_path=override.userinfo_path or default.userinfo_path,
        redirect_uri=(
            override.redirect_uri
            if override.redirect_uri != ""
            else default.redirect_uri
        ),
        prompt=override.prompt if override.prompt != "" else default.prompt,
        numeric_user_id=(
            override.numeric_user_id
            if override.numeric_user_id is not None
            else default.numeric_user_id
        ),
    )


def providers() -> dict[str, OAuthProvider]:
    oauth = load_config().oauth
    defaults = _defaults()
    result: dict[str, OAuthProvider] = {}
    for key, default in defaults.items():
        spec = _merge(default, oauth.providers.get(key))
        if key == "hikarinagi":
            spec.scopes = " ".join(dict.fromkeys([*spec.scopes.split(), "user:read"]))
            spec.numeric_user_id = True
        issuer = (spec.issuer or "").strip()
        client_id = (spec.client_id or "").strip()
        result[key] = OAuthProvider(
            key=key,
            label=spec.name or key,
            enabled=bool(spec.enabled and issuer and client_id),
            issuer=issuer,
            client_id=client_id,
            scopes=(spec.scopes or "openid profile").strip(),
            authorize_url=_join(issuer, spec.authorize_path),
            token_url=_join(issuer, spec.token_path),
            userinfo_url=_join(issuer, spec.userinfo_path),
            redirect_uri=(spec.redirect_uri or "").strip(),
            prompt=(spec.prompt or "").strip(),
            numeric_user_id=bool(spec.numeric_user_id),
        )
    return result


def provider(key: str) -> OAuthProvider | None:
    return providers().get((key or "").strip().lower())
