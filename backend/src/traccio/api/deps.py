"""Shared FastAPI dependencies for the API layer.

Route handlers live in per-resource modules under ``routers/`` and so cannot
close over request-scoped values the way the old single-file factory did; the
dependencies they share are declared here instead.
"""

import secrets
from collections.abc import Iterator
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, HTTPException, status

from traccio.core.config import Settings, get_settings
from traccio.core.crypto import TokenCipher, get_token_cipher
from traccio.providers.enable_banking.auth import load_private_key_pem
from traccio.providers.enable_banking.client import EnableBankingClient
from traccio.providers.enable_banking.provider import EnableBankingProvider


def current_user_id() -> UUID:
    """Return the id of the user the current request is scoped to.

    Traccio is a single-user service until real auth lands (blocked on the M4
    decision), so this resolves to ``Settings.dev_user_id``. Every query stays
    written ``scoped by user_id``; when auth arrives, only this one function
    changes — the routers keep depending on it unchanged.

    Returns
    -------
    UUID
        The current user's id.
    """
    return get_settings().dev_user_id


def require_api_token(
    settings: Annotated[Settings, Depends(get_settings)],
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    """Reject a request that doesn't carry ``Settings.api_token`` as a bearer token.

    A no-op when ``api_token`` is unset — the app keeps booting with no
    ``.env`` and every request stays unauthenticated, same as before this
    dependency existed. Set only for a deployment reachable from outside
    localhost (see ``docs/decisions/0014-api-token.md`` for why a shared
    token rather than real per-user auth, which is blocked on the M4
    decision). Compared with :func:`secrets.compare_digest` so response
    timing can't be used to guess the token a character at a time.

    Wired via ``dependencies=[Depends(require_api_token)]`` on a parent
    router in ``api/main.py`` covering every resource router except
    ``GET /health`` and ``GET /connections/callback`` — the latter is called
    by the bank's browser redirect, which cannot carry a bearer header, and
    is instead protected by its own unpredictable ``state`` value
    (``docs/openbanking.md``).

    Parameters
    ----------
    authorization : str or None
        The raw ``Authorization`` header, expected as ``Bearer <token>``.
    settings : Settings
        Injected so a test can override ``get_settings`` rather than
        mutating process-wide state.

    Raises
    ------
    HTTPException
        401 if ``api_token`` is set and the header is missing, malformed, or
        does not match.
    """
    if settings.api_token is None:
        return
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not secrets.compare_digest(token, settings.api_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )


def build_enable_banking_client() -> EnableBankingClient:
    """Construct the Enable Banking HTTP client from settings, outside FastAPI's DI.

    Requires the application id and a private key (inline PEM or a path to
    one) to be configured; a missing one is a misconfiguration and fails
    loudly here rather than deeper down. Split out of
    :func:`build_bank_provider` so a caller that needs raw provider access —
    an operational script under ``scripts/``, not a request handler — can get
    an authenticated client without also constructing an
    :class:`EnableBankingProvider`.

    Returns
    -------
    EnableBankingClient
        A client ready to call the Enable Banking API. The caller owns
        ``.close()``.
    """
    settings = get_settings()
    if settings.enable_banking_application_id is None:
        raise RuntimeError("TRACCIO_ENABLE_BANKING_APPLICATION_ID is not set")
    if settings.enable_banking_private_key_pem is not None:
        private_key_pem = settings.enable_banking_private_key_pem
    elif settings.enable_banking_private_key_path is not None:
        private_key_pem = load_private_key_pem(settings.enable_banking_private_key_path)
    else:
        raise RuntimeError(
            "neither TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PEM nor "
            "TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PATH is set"
        )

    return EnableBankingClient(
        application_id=settings.enable_banking_application_id,
        private_key_pem=private_key_pem,
        base_url=settings.enable_banking_base_url,
    )


def build_bank_provider() -> tuple[EnableBankingProvider, EnableBankingClient]:
    """Construct a bank provider and its underlying client, outside FastAPI's DI.

    Returns the client alongside the provider so the caller can close it —
    the two have different lifecycles depending on the caller:
    :func:`get_bank_provider` closes it when one request ends, while
    ``api/main.py``'s lifespan keeps one alive for the whole background
    scheduler's run (``services/scheduler.py``).

    Returns
    -------
    tuple[EnableBankingProvider, EnableBankingClient]
        The provider, and the client whose ``.close()`` the caller owns.
    """
    client = build_enable_banking_client()
    provider = EnableBankingProvider(client, send_psu_headers=get_settings().send_psu_headers)
    return provider, client


def get_bank_provider() -> Iterator[EnableBankingProvider]:
    """Yield the Enable Banking provider, built from settings.

    The underlying HTTP client is closed when the request ends. Tests
    override this dependency with a fake provider.

    Yields
    ------
    EnableBankingProvider
        A provider ready to start and complete authorizations.
    """
    provider, client = build_bank_provider()
    try:
        yield provider
    finally:
        client.close()


def get_token_cipher_dep() -> TokenCipher:
    """Return the token cipher for encrypting stored credentials at rest.

    Reads ``TRACCIO_ENCRYPTION_KEY`` from settings; :func:`get_token_cipher`
    raises if it is unset (encrypting a stored secret is impossible without it).
    Tests override this with a cipher built from a generated key.

    Returns
    -------
    TokenCipher
        A cipher ready to encrypt/decrypt.
    """
    return get_token_cipher(get_settings().encryption_key)
