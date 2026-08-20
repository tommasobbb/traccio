"""Tests for the Enable Banking consent adapter.

Offline: an ``httpx.MockTransport`` serves canned ``/auth`` and ``/sessions``
responses so no network is touched. Credentials are a synthetic in-test RSA key;
the session id and codes are synthetic (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from traccio.domain.enums import ConnectionStatus
from traccio.providers.base import AuthorizationStart, ProviderError, SyncContext
from traccio.providers.enable_banking.client import EnableBankingClient
from traccio.providers.enable_banking.provider import EnableBankingProvider

_APPLICATION_ID = "synthetic-app-id-01"
_SESSION_ID = "11111111-2222-3333-4444-555555555555"
_REDIRECT_URL = "https://localhost:8000/connections/callback"


def _synthetic_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")


def _provider(handler: httpx.MockTransport) -> EnableBankingProvider:
    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=handler,
    )
    return EnableBankingProvider(client)


def test_start_authorization_builds_auth_request_and_returns_start() -> None:
    """start_authorization POSTs a well-formed /auth body and returns the SCA url."""
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        captured["path"] = request.url.path
        captured["body"] = _json.loads(request.content)
        return httpx.Response(
            200, json={"url": "https://sca.example/authorize?x=1", "authorization_id": "auth-01"}
        )

    provider = _provider(httpx.MockTransport(handler))

    start = provider.start_authorization(
        institution="Test Bank 01", country="IT", redirect_url=_REDIRECT_URL
    )

    assert isinstance(start, AuthorizationStart)
    assert captured["path"] == "/auth"
    body = captured["body"]
    assert body["aspsp"] == {"name": "Test Bank 01", "country": "IT"}
    assert body["redirect_url"] == _REDIRECT_URL
    assert body["psu_type"] == "personal"
    assert body["state"]  # non-empty anti-CSRF token
    # valid_until is requested ~180 days out, timezone-aware.
    valid_until = datetime.fromisoformat(body["access"]["valid_until"])
    assert valid_until.tzinfo is not None
    assert 170 < (valid_until - datetime.now(UTC)).days <= 180
    # The returned session_reference is exactly the state that was sent.
    assert start.authorization_url == "https://sca.example/authorize?x=1"
    assert start.session_reference == body["state"]


def test_complete_authorization_exchanges_code_for_session() -> None:
    """A matching-state callback exchanges the code and maps to an AuthorizationResult."""
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        captured["path"] = request.url.path
        captured["body"] = _json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "session_id": _SESSION_ID,
                "accounts": [],
                "access": {"valid_until": "2027-02-16T00:00:00+00:00"},
            },
        )

    provider = _provider(httpx.MockTransport(handler))

    result = provider.complete_authorization(
        session_reference="STATE-01",
        callback_payload={"state": "STATE-01", "code": "AUTH-CODE-01"},
    )

    assert captured["path"] == "/sessions"
    assert captured["body"] == {"code": "AUTH-CODE-01"}
    assert result.credentials == _SESSION_ID
    assert result.status is ConnectionStatus.ACTIVE
    assert result.expires_at == datetime(2027, 2, 16, tzinfo=UTC)


def test_complete_authorization_rejects_state_mismatch() -> None:
    """A callback whose state does not match the reference is refused (CSRF guard)."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("/sessions must not be called on a state mismatch")

    provider = _provider(httpx.MockTransport(handler))

    with pytest.raises(ProviderError):
        provider.complete_authorization(
            session_reference="STATE-01",
            callback_payload={"state": "WRONG", "code": "AUTH-CODE-01"},
        )


def test_complete_authorization_surfaces_callback_error() -> None:
    """An error in the callback payload raises without echoing its detail."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("/sessions must not be called when the callback errored")

    provider = _provider(httpx.MockTransport(handler))

    with pytest.raises(ProviderError) as excinfo:
        provider.complete_authorization(
            session_reference="STATE-01",
            callback_payload={
                "state": "STATE-01",
                "error": "access_denied",
                "error_description": "user-secret-detail",
            },
        )

    assert "user-secret-detail" not in str(excinfo.value)


def test_authorization_result_hides_the_session_credential() -> None:
    """The session_id credential is excluded from repr so a whole-object log can't leak it."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "session_id": _SESSION_ID,
                "accounts": [],
                "access": {"valid_until": "2027-02-16T00:00:00+00:00"},
            },
        )

    provider = _provider(httpx.MockTransport(handler))

    result = provider.complete_authorization(
        session_reference="STATE-01",
        callback_payload={"state": "STATE-01", "code": "AUTH-CODE-01"},
    )

    assert _SESSION_ID not in repr(result)


def test_account_and_transaction_methods_are_not_yet_implemented() -> None:
    """The data-retrieval half of the adapter lands in a later slice."""
    provider = _provider(httpx.MockTransport(lambda request: httpx.Response(200, json={})))
    context = SyncContext(psu_present=True)

    with pytest.raises(NotImplementedError):
        provider.list_accounts(credentials=_SESSION_ID, context=context)


def test_provider_name_is_stable() -> None:
    """The provider identifier is stable and safe to log."""
    provider = _provider(httpx.MockTransport(lambda request: httpx.Response(200, json={})))

    assert provider.name == "enable_banking"
