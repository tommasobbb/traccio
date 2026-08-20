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
