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

from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, get_bank_provider, get_token_cipher_dep
from traccio.api.schemas.connections import (
    ConnectionResponse,
    ConnectionsResponse,
    StartConnectionRequest,
    StartConnectionResponse,
    SyncResponse,
)
from traccio.core.config import get_settings
from traccio.core.crypto import TokenCipher
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    activate_connection,
    create_connection,
    find_pending_connection_id,
    get_connection,
    get_connection_credentials,
    list_connections,
    mark_connection_synced,
    set_connection_auth_state,
    upsert_account,
    upsert_transaction,
)
from traccio.db.session import get_session
from traccio.domain.consent import consent_state
from traccio.domain.enums import ConnectionStatus, ConsentState
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
        country=body.country,
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


@router.post("/connections/{connection_id}/sync", response_model=SyncResponse)
def sync_connection(
    connection_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
    cipher: Annotated[TokenCipher, Depends(get_token_cipher_dep)],
) -> SyncResponse:
    """Sync the accounts and transactions reachable through an active connection.

    Reads the encrypted consent secret, decrypts it, lists the accounts the
    consent exposes and upserts each one, then fetches and upserts each account's
    transactions over a greedy history window. Idempotent on stable identity, so
    a re-sync updates rather than duplicates. Scoped to the current user.

    Refuses fast on a lapsed consent: a stored ``status`` of ``active`` does not
    by itself mean the 180-day consent window still holds (see
    ``domain/consent.py``), so this checks the *derived* state first rather than
    letting the provider call fail with an opaque error.

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
    SyncResponse
        How many accounts and transactions were discovered and persisted.
    """
    connection = get_connection(session, user_id=user_id, connection_id=connection_id)
    if connection is None:
        raise HTTPException(status_code=404, detail="unknown connection")
    settings = get_settings()
    state = consent_state(
        connection, now=datetime.now(UTC), warning_window_days=settings.consent_warning_window_days
    )
    if state is ConsentState.EXPIRED:
        raise HTTPException(status_code=409, detail="consent_expired")

    encrypted = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)
    if encrypted is None:
        raise HTTPException(status_code=404, detail="unknown or inactive connection")

    credentials = cipher.decrypt(encrypted)
    # PSU-present: the user is actively waiting, so this is not subject to the
    # background fetch budget (docs/openbanking.md).
    context = SyncContext(psu_present=True)
    now = datetime.now(UTC)
    since = now - timedelta(days=settings.initial_history_days)
    try:
        provider_accounts = provider.list_accounts(credentials=credentials, context=context)
        transactions_synced = 0
        for provider_account in provider_accounts:
            account = upsert_account(
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
            transactions = provider.fetch_transactions(
                credentials=credentials,
                account=account,
                since=since,
                until=None,
                context=context,
            )
            for transaction in transactions:
                upsert_transaction(session, transaction=transaction, now=now)
            transactions_synced += len(transactions)
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider sync failed") from exc

    mark_connection_synced(session, user_id=user_id, connection_id=connection_id, now=now)
    session.commit()

    logger.info(
        "connections.sync",
        connection_id=str(connection_id),
        accounts_synced=len(provider_accounts),
        transactions_synced=transactions_synced,
    )
    return SyncResponse(
        accounts_synced=len(provider_accounts),
        transactions_synced=transactions_synced,
    )


@router.get("/connections", response_model=ConnectionsResponse)
def connections(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ConnectionsResponse:
    """List the current user's bank connections, oldest first.

    Scoped to the current user. Secret material never leaves ``db/``, so the
    projection cannot expose the consent secret or ``auth_state`` (see
    ``.claude/rules/data-safety.md``).

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose connections to return.

    Returns
    -------
    ConnectionsResponse
        The user's connections, oldest first.
    """
    found = list_connections(session, user_id)
    # Log a count, never connection contents (see data-safety rules).
    logger.info("connections.list", count=len(found))
    now = datetime.now(UTC)
    warning_window_days = get_settings().consent_warning_window_days
    return ConnectionsResponse(
        connections=[
            ConnectionResponse.from_domain(
                connection, now=now, warning_window_days=warning_window_days
            )
            for connection in found
        ]
    )


@router.post("/connections/{connection_id}/reauthorize", response_model=StartConnectionResponse)
def reauthorize_connection(
    connection_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
) -> StartConnectionResponse:
    """Re-authorize an existing connection whose consent has lapsed or is close to it.

    Unlike ``POST /connections``, this does not create a new connection: it
    re-arms the existing row with a freshly issued anti-CSRF ``state`` and starts
    a new SCA authorization for the same institution and country. Completing it
    through the usual ``GET /connections/callback`` activates this same
    connection in place — its accounts and their transaction history stay
    attached, since Enable Banking documents ``identification_hash`` as stable
    across re-authorizations (``docs/openbanking.md``). Scoped to the current
    user.

    Parameters
    ----------
    connection_id : UUID
        The connection to re-authorize.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the connection belongs to.
    provider : BankProvider
        The bank adapter (Enable Banking).

    Returns
    -------
    StartConnectionResponse
        The same connection id and a fresh authorization url.
    """
    connection = get_connection(session, user_id=user_id, connection_id=connection_id)
    if connection is None:
        raise HTTPException(status_code=404, detail="unknown connection")
    if connection.country is None:
        # Created before `country` was persisted; nothing to re-authorize with.
        # The client falls back to POST /connections for a fresh connection.
        raise HTTPException(status_code=409, detail="country_unknown")

    redirect_url = get_settings().enable_banking_redirect_url
    try:
        start = provider.start_authorization(
            institution=connection.institution_name,
            country=connection.country,
            redirect_url=redirect_url,
        )
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider authorization failed") from exc

    set_connection_auth_state(
        session, user_id=user_id, connection_id=connection_id, auth_state=start.session_reference
    )
    session.commit()

    logger.info("connections.reauthorize", connection_id=str(connection_id))
    return StartConnectionResponse(
        connection_id=connection_id, authorization_url=start.authorization_url
    )
