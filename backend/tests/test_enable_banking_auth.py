"""Tests for Enable Banking bearer JWT minting.

Pure unit tests: no network, no real credentials. The RSA keypair is generated
in-test and is entirely synthetic (see ``docs/engineering.md``).
"""

import base64
import json
from datetime import UTC, datetime

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey

from traccio.providers.enable_banking.auth import mint_bearer_jwt

_APPLICATION_ID = "synthetic-app-id-01"


def _generate_private_key() -> RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _pem(key: RSAPrivateKey) -> str:
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")


def _b64url_decode(segment: str) -> bytes:
    padding_needed = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding_needed)


def _decode_part(segment: str) -> dict[str, object]:
    return json.loads(_b64url_decode(segment))


def test_header_and_claims_match_enable_banking_scheme() -> None:
    """The JWT carries the header and claims Enable Banking requires."""
    now = datetime(2026, 8, 20, 12, 0, 0, tzinfo=UTC)
    ttl = 3600

    token = mint_bearer_jwt(
        application_id=_APPLICATION_ID,
        private_key_pem=_pem(_generate_private_key()),
        now=now,
        ttl_seconds=ttl,
    )

    header_segment, claims_segment, _ = token.split(".")
    header = _decode_part(header_segment)
    claims = _decode_part(claims_segment)

    assert header == {"alg": "RS256", "kid": _APPLICATION_ID, "typ": "JWT"}
    assert claims["iss"] == "enablebanking.com"
    assert claims["aud"] == "api.enablebanking.com"
    assert claims["iat"] == int(now.timestamp())
    assert claims["exp"] == int(now.timestamp()) + ttl


def test_signature_verifies_with_the_public_key() -> None:
    """The signature is a valid RS256 signature over the signing input."""
    key = _generate_private_key()

    token = mint_bearer_jwt(application_id=_APPLICATION_ID, private_key_pem=_pem(key))

    header_segment, claims_segment, signature_segment = token.split(".")
    signing_input = f"{header_segment}.{claims_segment}".encode("ascii")

    # Raises InvalidSignature if the signature does not verify.
    key.public_key().verify(
        _b64url_decode(signature_segment),
        signing_input,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )


def test_tampered_payload_fails_verification() -> None:
    """A modified payload no longer matches the signature."""
    from cryptography.exceptions import InvalidSignature

    key = _generate_private_key()
    token = mint_bearer_jwt(application_id=_APPLICATION_ID, private_key_pem=_pem(key))
    header_segment, _, signature_segment = token.split(".")

    forged_segment = (
        base64.urlsafe_b64encode(json.dumps({"iss": "attacker"}).encode())
        .rstrip(b"=")
        .decode("ascii")
    )
    tampered_input = f"{header_segment}.{forged_segment}".encode("ascii")

    with pytest.raises(InvalidSignature):
        key.public_key().verify(
            _b64url_decode(signature_segment),
            tampered_input,
            padding.PKCS1v15(),
            hashes.SHA256(),
        )


def test_malformed_private_key_raises_without_leaking_it() -> None:
    """A bad PEM raises a stable, value-free error (data-safety)."""
    bad_pem = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-NOT-A-KEY\n-----END PRIVATE KEY-----"

    with pytest.raises(ValueError) as excinfo:
        mint_bearer_jwt(application_id=_APPLICATION_ID, private_key_pem=bad_pem)

    assert "SYNTHETIC-NOT-A-KEY" not in str(excinfo.value)


def test_non_rsa_key_is_rejected() -> None:
    """A non-RSA key is rejected — Enable Banking requires RS256."""
    from cryptography.hazmat.primitives.asymmetric import ed25519

    ed_pem = (
        ed25519.Ed25519PrivateKey.generate()
        .private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        .decode("ascii")
    )

    with pytest.raises(ValueError):
        mint_bearer_jwt(application_id=_APPLICATION_ID, private_key_pem=ed_pem)
