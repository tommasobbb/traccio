"""Bearer JWT minting for Enable Banking API authentication.

Every Enable Banking API request is authorized with a short-lived JWT signed
**RS256** using the application's private RSA key (the ``<application-id>.pem``
downloaded during onboarding). The scheme is fixed by the provider and recorded
in ``docs/openbanking.md`` (§Onboarding, step 5):

- header: ``alg=RS256``, ``kid=<application id>``, ``typ=JWT``
- claims: ``iss=enablebanking.com``, ``aud=api.enablebanking.com``, ``iat`` now,
  ``exp`` now + TTL (3600s)

The JWT is not a stored credential — it is minted per request/session by the
adapter and expires within the hour. The **private key is** the credential: it
is loaded from a file whose path comes from configuration, never committed,
never logged (``docs/openbanking.md`` §Credential handling).

Like :mod:`traccio.core.crypto`, this module takes the key material as a plain
argument rather than importing :mod:`traccio.core.config`, so the layering rule
holds (``providers/`` imports only ``domain`` plus stdlib/third-party); the
caller reads the path from settings and passes the loaded PEM in.

Data safety (``docs/engineering.md``): this module never logs, and no
exception it raises contains the private key or the minted token.
"""

import base64
import json
from datetime import UTC, datetime

from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey

_ISSUER = "enablebanking.com"
_AUDIENCE = "api.enablebanking.com"
_DEFAULT_TTL_SECONDS = 3600


def _b64url(raw: bytes) -> str:
    """Return ``raw`` as unpadded base64url text (JWS/JWT encoding)."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _load_rsa_private_key(private_key_pem: str) -> RSAPrivateKey:
    """Parse a PEM string into an RSA private key.

    Raises
    ------
    ValueError
        If the PEM is malformed or is not an RSA key. The message is stable and
        value-free — it never contains the key material (data-safety).
    """
    try:
        key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    except (ValueError, TypeError, UnsupportedAlgorithm) as exc:
        # Do not chain the original message verbatim into any log; the wrapped
        # exception can carry OpenSSL detail but never the key value itself.
        raise ValueError("invalid Enable Banking private key") from exc
    if not isinstance(key, RSAPrivateKey):
        raise ValueError("Enable Banking private key must be an RSA key")
    return key


def mint_bearer_jwt(
    *,
    application_id: str,
    private_key_pem: str,
    now: datetime | None = None,
    ttl_seconds: int = _DEFAULT_TTL_SECONDS,
) -> str:
    """Mint a short-lived RS256 bearer JWT for the Enable Banking API.

    Parameters
    ----------
    application_id : str
        The Enable Banking application ID. Becomes the JWT ``kid`` header; it
        identifies the application, not a secret, so it is safe to log.
    private_key_pem : str
        The application's RSA private key in PEM form (the ``<app-id>.pem``
        contents). Secret — never logged; a malformed value raises
        :class:`ValueError` without leaking it.
    now : datetime or None, optional
        The reference time for ``iat``/``exp`` (timezone-aware). Defaults to the
        current UTC time; injectable for deterministic tests.
    ttl_seconds : int, optional
        Token lifetime in seconds. Defaults to 3600 (the value Enable Banking
        expects).

    Returns
    -------
    str
        The signed JWT to send as ``Authorization: Bearer <jwt>``. Secret (it
        authorizes API calls) — never logged.
    """
    issued_at = now if now is not None else datetime.now(UTC)
    iat = int(issued_at.timestamp())
    exp = iat + ttl_seconds

    header = {"alg": "RS256", "kid": application_id, "typ": "JWT"}
    claims = {"iss": _ISSUER, "aud": _AUDIENCE, "iat": iat, "exp": exp}

    # Compact, deterministic JSON so the signing input is stable.
    segments = [
        _b64url(json.dumps(header, separators=(",", ":"), sort_keys=True).encode()),
        _b64url(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode()),
    ]
    signing_input = ".".join(segments).encode("ascii")

    key = _load_rsa_private_key(private_key_pem)
    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    segments.append(_b64url(signature))
    return ".".join(segments)


def load_private_key_pem(path: str) -> str:
    """Read the application private key PEM from ``path``.

    A thin wrapper for callers that hold the key file path in settings
    (``get_settings().enable_banking_private_key_path``). Kept separate from
    :func:`mint_bearer_jwt` so minting stays a pure function testable with an
    in-memory key.

    Parameters
    ----------
    path : str
        Filesystem path to the ``<application-id>.pem`` private key.

    Returns
    -------
    str
        The PEM contents. Secret — never logged.
    """
    with open(path, encoding="ascii") as handle:
        return handle.read()
