"""Shared FastAPI dependencies for the API layer.

Route handlers live in per-resource modules under ``routers/`` and so cannot
close over request-scoped values the way the old single-file factory did; the
dependencies they share are declared here instead.
"""

from collections.abc import Iterator
from uuid import UUID

from traccio.core.config import get_settings
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


def get_bank_provider() -> Iterator[EnableBankingProvider]:
    """Yield the Enable Banking provider, built from settings.

    Requires the Enable Banking application id and private-key path to be
    configured; a missing one is a misconfiguration and fails loudly here rather
    than deeper down. The underlying HTTP client is closed when the request ends.
    Tests override this dependency with a fake provider.

    Yields
    ------
    EnableBankingProvider
        A provider ready to start and complete authorizations.
    """
    settings = get_settings()
    if settings.enable_banking_application_id is None:
        raise RuntimeError("TRACCIO_ENABLE_BANKING_APPLICATION_ID is not set")
    if settings.enable_banking_private_key_path is None:
        raise RuntimeError("TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PATH is not set")

    client = EnableBankingClient(
        application_id=settings.enable_banking_application_id,
        private_key_pem=load_private_key_pem(settings.enable_banking_private_key_path),
        base_url=settings.enable_banking_base_url,
    )
    try:
        yield EnableBankingProvider(client)
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
