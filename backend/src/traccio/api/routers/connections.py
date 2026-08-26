"""Bank connection (consent) endpoints.

Two steps of one flow (see ``docs/openbanking.md`` §Consent flow):

- ``POST /connections`` starts an authorization: it creates a pending
  :class:`~traccio.domain.models.Connection` and returns the SCA url to open in
  the system browser.
- ``GET /connections/callback`` completes it: the bank redirects the user here
  after SCA; the code is exchanged for a session and the consent secret is
  encrypted at rest.

Two ``APIRouter`` instances, not one: ``router`` holds every endpoint that
needs ``api/deps.py::require_api_token`` (ADR 0014), while ``callback_router``
holds only the callback — the bank's browser redirect cannot carry a bearer
header, so ``api/main.py`` includes it without that dependency. The callback
stays protected by its own unpredictable ``state`` value instead.

Data safety (``.claude/rules/data-safety.md``): these handlers log only the
``connection_id`` and outcome — never the ``code``, ``state``, ``session_id``,
or the authorization url (which embeds ``state``).
"""

from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, get_bank_provider, get_token_cipher_dep
from traccio.api.schemas.connections import (
    ConnectionResponse,
    ConnectionsResponse,
    InstitutionResponse,
    InstitutionsResponse,
    StartConnectionRequest,
    StartConnectionResponse,
    SyncResponse,
)
from traccio.core.config import Settings, get_settings
from traccio.core.crypto import TokenCipher
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    activate_connection,
    count_recent_sync_runs,
    create_connection,
    find_pending_connection_id,
    get_connection,
    list_connections,
    oldest_recent_sync_run_started_at,
    set_connection_auth_state,
)
from traccio.db.session import get_session
from traccio.domain.consent import consent_state as derive_consent_state
from traccio.domain.enums import ConnectionStatus
from traccio.domain.models import Connection
from traccio.domain.sync_schedule import next_sync_eligible_at
from traccio.providers.base import BankProvider, ProviderError, SyncContext
from traccio.services.sync import (
    ConnectionNotFoundError,
    ConsentExpiredError,
    CredentialsUnavailableError,
)
from traccio.services.sync import (
    sync_connection as run_sync,
)

logger = get_logger(__name__)

router = APIRouter()
callback_router = APIRouter()

_SUCCESS_PAGE = """<!doctype html>
<html lang="it"><head><meta charset="utf-8"><title>Traccio</title></head>
<body style="font-family: system-ui, sans-serif; text-align: center; padding: 3rem;">
<h1>Connessione completata</h1>
<p>Puoi chiudere questa scheda e tornare all'app.</p>
</body></html>
"""


@router.get("/connections/institutions", response_model=InstitutionsResponse)
def list_institutions(
    provider: Annotated[BankProvider, Depends(get_bank_provider)],
    country: Annotated[str, Query()] = "IT",
) -> InstitutionsResponse:
    """List the banks the provider supports authorizing in ``country``.

    Feeds a client-side picker for ``POST /connections``'s ``institution``
    field, so "Collega un nuovo conto" no longer needs the user (or the
    client) to already know a bank's exact provider-scoped name. Public
    institution metadata only — not user-scoped, unlike every other endpoint
    on this router.

    Parameters
    ----------
    provider : BankProvider
        The bank adapter (Enable Banking).
    country : str, optional
        ISO 3166-1 alpha-2 country code. Defaults to ``"IT"``.

    Returns
    -------
    InstitutionsResponse
        The institutions offered in ``country``, in the provider's own order.

    Raises
    ------
    HTTPException
        502 if the provider lookup fails.
    """
    try:
        institutions = provider.list_institutions(country=country)
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider institution lookup failed") from exc

    # Log the country and a count only — institution names are public, but
    # there is nothing this handler needs to log beyond that (data-safety
    # rules err toward identifiers/counts everywhere on this router).
    logger.info("connections.institutions", country=country, count=len(institutions))
    return InstitutionsResponse(
        institutions=[InstitutionResponse.from_domain(institution) for institution in institutions]
    )


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


@callback_router.get("/connections/callback", response_class=HTMLResponse)
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

    A thin HTTP wrapper: the orchestration itself
    (:func:`~traccio.services.sync.sync_connection`) is shared with the
    background scheduler (``services/scheduler.py``), so a user-triggered sync
    and a scheduled one go through the exact same path. This handler's own job
    is PSU-present context (a user is actively waiting, so this is not subject
    to the background fetch budget — ``docs/openbanking.md``), translating the
    service's exceptions into the right status code, and committing on success.

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
    settings = get_settings()
    context = SyncContext(psu_present=True)
    try:
        outcome = run_sync(
            session,
            provider=provider,
            cipher=cipher,
            user_id=user_id,
            connection_id=connection_id,
            context=context,
            initial_history_days=settings.initial_history_days,
            sync_overlap_days=settings.sync_overlap_days,
            consent_warning_window_days=settings.consent_warning_window_days,
            now=datetime.now(UTC),
        )
    except ConnectionNotFoundError as exc:
        raise HTTPException(status_code=404, detail="unknown connection") from exc
    except ConsentExpiredError as exc:
        raise HTTPException(status_code=409, detail="consent_expired") from exc
    except CredentialsUnavailableError as exc:
        raise HTTPException(status_code=404, detail="unknown or inactive connection") from exc
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail="provider sync failed") from exc

    session.commit()

    logger.info(
        "connections.sync",
        connection_id=str(connection_id),
        accounts_synced=outcome.accounts_synced,
        transactions_synced=outcome.transactions_synced,
    )
    return SyncResponse(
        accounts_synced=outcome.accounts_synced,
        transactions_synced=outcome.transactions_synced,
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
    settings = get_settings()
    responses = []
    for connection in found:
        budget_remaining, next_sync_at = _scheduler_projection(
            session, connection, now=now, settings=settings
        )
        responses.append(
            ConnectionResponse.from_domain(
                connection,
                now=now,
                warning_window_days=settings.consent_warning_window_days,
                background_sync_enabled=settings.background_sync_enabled,
                sync_budget_remaining=budget_remaining,
                next_sync_at=next_sync_at,
            )
        )
    return ConnectionsResponse(connections=responses)


def _scheduler_projection(
    session: Session, connection: Connection, *, now: datetime, settings: Settings
) -> tuple[int | None, datetime | None]:
    """Derive one connection's ``sync_budget_remaining``/``next_sync_at``.

    Both are ``None`` when the scheduler is disabled — there is nothing
    meaningful to show if nothing is scheduling syncs
    (``ConnectionResponse.from_domain``'s docstring). Derived fresh on every
    call, never stored (ADR 0006's discipline, same as ``consent_state``).

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    connection : Connection
        The connection to project.
    now : datetime
        The current time.
    settings : Settings
        Read for the scheduler's on/off flag and budget/interval knobs.

    Returns
    -------
    tuple[int or None, datetime or None]
        ``(sync_budget_remaining, next_sync_at)``.
    """
    if not settings.background_sync_enabled:
        return None, None

    since = now - timedelta(hours=24)
    runs_last_24h = count_recent_sync_runs(session, connection_id=connection.id, since=since)
    oldest_run_started_at = oldest_recent_sync_run_started_at(
        session, connection_id=connection.id, since=since
    )
    state = derive_consent_state(
        connection, now=now, warning_window_days=settings.consent_warning_window_days
    )
    budget_remaining = max(0, settings.background_sync_budget_per_day - runs_last_24h)
    next_sync_at = next_sync_eligible_at(
        consent_state=state,
        runs_last_24h=runs_last_24h,
        oldest_run_started_at=oldest_run_started_at,
        last_synced_at=connection.last_synced_at,
        now=now,
        budget_per_day=settings.background_sync_budget_per_day,
        min_interval_hours=settings.sync_min_interval_hours,
    )
    return budget_remaining, next_sync_at


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
