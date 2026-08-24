"""Tests for the Enable Banking HTTP client.

Offline: an ``httpx.MockTransport`` serves canned responses so no network is
touched. Credentials are a synthetic in-test RSA key; the ASPSP payload is
synthetic institution metadata (no personal data).
"""

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from traccio.providers.base import ProviderError
from traccio.providers.enable_banking.client import EnableBankingClient

_APPLICATION_ID = "synthetic-app-id-01"


def _synthetic_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")


def test_list_aspsps_sends_bearer_and_country() -> None:
    """The client authenticates with a bearer JWT and queries the right path."""
    seen: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["country"] = request.url.params.get("country")
        seen["authorization"] = request.headers.get("Authorization")
        return httpx.Response(200, json={"aspsps": [{"name": "Test Bank 01", "country": "IT"}]})

    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=httpx.MockTransport(handler),
    )
    with client:
        aspsps = client.list_aspsps("IT")

    assert seen["path"] == "/aspsps"
    assert seen["country"] == "IT"
    authorization = seen["authorization"]
    assert isinstance(authorization, str) and authorization.startswith("Bearer ")
    # A bearer JWT has three dot-separated segments.
    assert authorization.removeprefix("Bearer ").count(".") == 2
    assert aspsps == [{"name": "Test Bank 01", "country": "IT"}]


def test_list_aspsps_wraps_error_status_in_provider_error() -> None:
    """A non-2xx response surfaces as a value-free ProviderError, not the body."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "unauthorized-secret-detail"})

    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=httpx.MockTransport(handler),
    )
    with client, pytest.raises(ProviderError) as excinfo:
        client.list_aspsps("IT")

    # The provider response body must not leak into the raised message.
    assert "unauthorized-secret-detail" not in str(excinfo.value)


def test_get_session_attaches_extra_headers_when_given() -> None:
    """extra_headers (the PSU-present set, ADR 0011) ride alongside the bearer JWT."""
    seen_headers: dict[str, str | None] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen_headers["Psu-User-Agent"] = request.headers.get("Psu-User-Agent")
        seen_headers["Authorization"] = request.headers.get("Authorization")
        return httpx.Response(200, json={"accounts": []})

    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=httpx.MockTransport(handler),
    )
    with client:
        client.get_session("SESSION-01", extra_headers={"Psu-User-Agent": "Traccio/1.0"})

    assert seen_headers["Psu-User-Agent"] == "Traccio/1.0"
    # extra_headers augment, never replace, the bearer authentication.
    authorization = seen_headers["Authorization"]
    assert isinstance(authorization, str) and authorization.startswith("Bearer ")


def test_get_session_sends_no_psu_header_when_extra_headers_is_none() -> None:
    """The default (no extra_headers) — today's real behavior — carries none."""
    seen: dict[str, str | None] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["Psu-User-Agent"] = request.headers.get("Psu-User-Agent")
        return httpx.Response(200, json={"accounts": []})

    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=httpx.MockTransport(handler),
    )
    with client:
        client.get_session("SESSION-01")

    assert seen["Psu-User-Agent"] is None


def test_get_account_details_and_get_account_transactions_also_attach_extra_headers() -> None:
    """The other two data-retrieval calls thread extra_headers the same way."""
    seen: list[str | None] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers.get("Psu-User-Agent"))
        if request.url.path.endswith("/details"):
            return httpx.Response(200, json={})
        return httpx.Response(200, json={"transactions": []})

    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=httpx.MockTransport(handler),
    )
    headers = {"Psu-User-Agent": "Traccio/1.0"}
    with client:
        client.get_account_details("uid-01", extra_headers=headers)
        client.get_account_transactions("uid-01", date_from="2026-01-01", extra_headers=headers)

    assert seen == ["Traccio/1.0", "Traccio/1.0"]
