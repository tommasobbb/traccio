"""Bank connection (consent) endpoints.

Two steps of one flow (see ``docs/openbanking.md`` §Consent flow):

- ``POST /connections`` starts an authorization: it creates a pending
  :class:`~traccio.domain.models.Connection` and returns the SCA url to open in
  the system browser.
- ``GET /connections/callback`` completes it: the bank redirects the user here
  after SCA; the code is exchanged for a session and the consent secret is
  encrypted at rest.

Data safety (``.claude/rules/data-safety.md``): these handlers log only the
``connection_id`` and outcome — never the ``code``, ``state``, ``session_id``,
or the authorization url (which embeds ``state``).
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, get_bank_provider, get_token_cipher_dep
from traccio.api.schemas.connections import (
    StartConnectionRequest,
    StartConnectionResponse,
    SyncAccountsResponse,
)
from traccio.core.config import get_settings
from traccio.core.crypto import TokenCipher
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    activate_connection,
    create_connection,
    find_pending_connection_id,
    get_connection_credentials,
    upsert_account,
)
from traccio.db.session import get_session
from traccio.domain.enums import ConnectionStatus
from traccio.domain.models import Account, Connection
from traccio.providers.base import BankProvider, ProviderError, SyncContext

logger = get_logger(__name__)

router = APIRouter()

_SUCCESS_PAGE = """<!doctype html>
<html lang="it"><head><meta charset="utf-8"><title>Traccio</title></head>
<body style="font-family: system-ui, sans-serif; text-align: center; padding: 3rem;">
<h1>Connessione completata</h1>
<p>Puoi chiudere questa scheda e tornare all'app.</p>
</body></html>
"""


@router.post("/connections", response_model=StartConnectionResponse)
def start_connection(
    body: StartConnectionRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
) -> StartConnectionResponse:
    """Begin authorizing a bank connection.

    Creates a pending connection and returns the URL to open in the system
    browser for SCA. Scoped to the current user.

    Parameters
    ----------
    body : StartConnectionRequest
        The bank to authorize (institution + country).
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the connection belongs to.
    provider : BankProvider
        The bank adapter (Enable Banking).

    Returns
    -------
    StartConnectionResponse
        The pending connection id and the authorization url.
    """
    redirect_url = get_settings().enable_banking_redirect_url
    try:
        start = provider.start_authorization(
            institution=body.institution, country=body.country, redirect_url=redirect_url
        )
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider authorization failed") from exc

    connection = Connection(
        user_id=user_id,
        provider=provider.name,
        institution_name=body.institution,
        status=ConnectionStatus.PENDING,
    )
    create_connection(session, connection=connection, auth_state=start.session_reference)
    session.commit()

    logger.info("connections.start", connection_id=str(connection.id))
    return StartConnectionResponse(
        connection_id=connection.id, authorization_url=start.authorization_url
    )


@router.get("/connections/callback", response_class=HTMLResponse)
def connection_callback(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
    cipher: Annotated[TokenCipher, Depends(get_token_cipher_dep)],
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    error_description: str | None = None,
) -> HTMLResponse:
    """Complete an authorization after the bank's SCA redirect.

    Matches the callback to its pending connection by ``state``, exchanges the
    code for a session, encrypts the consent secret at rest, and activates the
    connection. Scoped to the current user.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the connection belongs to.
    provider : BankProvider
        The bank adapter (Enable Banking).
    cipher : Fernet cipher
        Encrypts the consent secret before it is stored.
    code, state, error, error_description : str or None
        The query parameters the bank appended to the redirect.

    Returns
    -------
    HTMLResponse
        A small success page for the browser tab.
    """
    if state is None:
        raise HTTPException(status_code=404, detail="unknown or expired authorization")
    connection_id = find_pending_connection_id(session, user_id=user_id, auth_state=state)
    if connection_id is None:
        raise HTTPException(status_code=404, detail="unknown or expired authorization")

    # Only forward the parameters actually present; the adapter validates state
    # and surfaces any bank error.
    payload = {
        key: value
        for key, value in (
            ("code", code),
            ("state", state),
            ("error", error),
            ("error_description", error_description),
        )
        if value is not None
    }
    try:
        result = provider.complete_authorization(session_reference=state, callback_payload=payload)
    except ProviderError as exc:
        raise HTTPException(status_code=400, detail="authorization failed") from exc

    activate_connection(
        session,
        user_id=user_id,
        connection_id=connection_id,
        encrypted_credentials=cipher.encrypt(result.credentials),
        expires_at=result.expires_at,
    )
    session.commit()

    logger.info("connections.callback", connection_id=str(connection_id), status="active")
    return HTMLResponse(content=_SUCCESS_PAGE)


@router.post("/connections/{connection_id}/sync", response_model=SyncAccountsResponse)
def sync_connection(
    connection_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
    cipher: Annotated[TokenCipher, Depends(get_token_cipher_dep)],
) -> SyncAccountsResponse:
    """Sync the accounts reachable through an active connection.

    Reads the encrypted consent secret, decrypts it, lists the accounts the
    consent exposes, and upserts each one (idempotent on stable identity, so a
    re-sync updates rather than duplicates). Scoped to the current user. This
    slice discovers accounts only; transactions join this endpoint later.

    Parameters
    ----------
    connection_id : UUID
        The active connection to sync.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the connection belongs to.
    provider : BankProvider
        The bank adapter (Enable Banking).
    cipher : Fernet cipher
        Decrypts the stored consent secret.

    Returns
    -------
    SyncAccountsResponse
        How many accounts were discovered and persisted.
    """
    encrypted = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)
    if encrypted is None:
        raise HTTPException(status_code=404, detail="unknown or inactive connection")

    credentials = cipher.decrypt(encrypted)
    try:
        provider_accounts = provider.list_accounts(
            credentials=credentials, context=SyncContext(psu_present=True)
        )
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider account listing failed") from exc

    for provider_account in provider_accounts:
        upsert_account(
            session,
            account=Account(
                user_id=user_id,
                connection_id=connection_id,
                kind=provider_account.kind,
                currency=provider_account.currency,
                identification_hash=provider_account.identification_hash,
                name=provider_account.name,
            ),
        )
    session.commit()

    logger.info(
        "connections.sync",
        connection_id=str(connection_id),
        accounts_synced=len(provider_accounts),
    )
    return SyncAccountsResponse(accounts_synced=len(provider_accounts))
