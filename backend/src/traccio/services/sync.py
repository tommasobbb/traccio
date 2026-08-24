"""Orchestrate one connection's sync: fetch, normalize, deduplicate, persist.

The single path both a user-triggered sync (``POST /connections/{id}/sync``)
and a scheduled background sync (:mod:`traccio.services.scheduler`) go
through — see ``docs/architecture.md``'s pipeline: fetch -> normalize (the
adapter) -> deduplicate -> persist -> run detection -> record outcome.
Extracted from ``api/routers/connections.py`` so the scheduler can call
exactly the same path an HTTP-triggered sync uses, rather than a second copy
of the orchestration.

Unlike :mod:`traccio.services.advances`, :mod:`traccio.services.categorization`,
and :mod:`traccio.services.transfers` (all pure, importing only ``domain``),
this module orchestrates real I/O: it decrypts a stored credential, calls the
bank adapter, and writes rows. ``services/`` was widened to import ``db``,
``providers``, and ``core`` for exactly this reason — see
``docs/decisions/0010-background-sync-scheduler.md``. It still may not import
``api``: HTTP concerns (status codes, request/response schemas) stay in the
router, which translates the exceptions below and
:class:`~traccio.providers.base.ProviderError` into the right
``HTTPException``.

This module does not commit. Like every function in ``db/repositories.py``,
the caller owns the transaction boundary — the router commits after a
successful call, and so does the scheduler.
"""

from datetime import datetime, timedelta
from uuid import UUID

from pydantic import BaseModel, ConfigDict
from sqlalchemy.orm import Session

from traccio.core.crypto import TokenCipher
from traccio.db.repositories import (
    get_connection,
    get_connection_credentials,
    mark_connection_synced,
    upsert_account,
    upsert_transaction,
)
from traccio.domain.consent import consent_state
from traccio.domain.enums import ConsentState
from traccio.domain.models import Account
from traccio.providers.base import BankProvider, SyncContext


class SyncError(ValueError):
    """Base for a sync that could not proceed.

    Distinct subclasses, not a shared reason code (contrast
    ``domain/rules.py::RuleError``), because each one maps to a different
    HTTP status in the router — one flat reason string would just be
    re-parsed back into a branch there.
    """


class ConnectionNotFoundError(SyncError):
    """No connection with this id belongs to the user."""


class ConsentExpiredError(SyncError):
    """The derived consent state (``domain/consent.py``) has lapsed.

    Raised before the provider is ever called, so the caller can distinguish
    "retry" from "re-authorize" (ADR 0006).
    """


class CredentialsUnavailableError(SyncError):
    """The connection has no usable stored credentials right now.

    Covers a pending, revoked, or otherwise inactive connection — anything
    :func:`~traccio.db.repositories.get_connection_credentials` returns
    ``None`` for.
    """


class SyncOutcome(BaseModel):
    """What one sync run discovered and persisted.

    Attributes
    ----------
    accounts_synced : int
        How many accounts were listed and upserted.
    transactions_synced : int
        How many transactions were fetched and upserted, across all accounts.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    accounts_synced: int
    transactions_synced: int


def sync_connection(
    session: Session,
    *,
    provider: BankProvider,
    cipher: TokenCipher,
    user_id: UUID,
    connection_id: UUID,
    context: SyncContext,
    initial_history_days: int,
    consent_warning_window_days: int,
    now: datetime,
) -> SyncOutcome:
    """Sync the accounts and transactions reachable through one connection.

    Reads the encrypted consent secret, decrypts it, lists the accounts the
    consent exposes and upserts each one, then fetches and upserts each
    account's transactions over a greedy history window. Idempotent on stable
    identity (``upsert_account``/``upsert_transaction``), so a re-sync
    updates rather than duplicates. Scoped to ``user_id``.

    Refuses fast on a lapsed consent: a stored ``status`` of ``active`` does
    not by itself mean the 180-day consent window still holds (see
    ``domain/consent.py``), so this checks the *derived* state first rather
    than letting the provider call fail with an opaque error.

    Parameters
    ----------
    session : Session
        Active database session. Not committed here — see the module
        docstring.
    provider : BankProvider
        The bank adapter to sync through.
    cipher : TokenCipher
        Decrypts the stored consent secret.
    user_id : UUID
        The user the connection belongs to.
    connection_id : UUID
        The connection to sync.
    context : SyncContext
        Whether a user is actively waiting (``psu_present=True``, not subject
        to the background fetch budget) or this is an unattended background
        run (``psu_present=False``, budget-gated by the caller before this
        function is ever called — see ``services/scheduler.py``).
    initial_history_days : int
        How far back to request transactions
        (``Settings.initial_history_days``). Passed as a plain value, not a
        ``Settings`` object, so this module stays decoupled from ``core``'s
        specific shape (the same reasoning as ``core/logging.py``'s
        keyword-only, plain-valued ``configure_logging``).
    consent_warning_window_days : int
        Passed through to :func:`~traccio.domain.consent.consent_state`
        (``Settings.consent_warning_window_days``).
    now : datetime
        The current time, timezone-aware. Passed in rather than read
        internally so this stays testable with no clock.

    Returns
    -------
    SyncOutcome
        How many accounts and transactions were discovered and persisted.

    Raises
    ------
    ConnectionNotFoundError
        No connection with ``connection_id`` belongs to ``user_id``.
    ConsentExpiredError
        The derived consent state has lapsed.
    CredentialsUnavailableError
        The connection has no usable stored credentials.
    ProviderError
        The bank adapter call failed. Propagated unchanged — the caller (the
        router, or the scheduler) decides how to translate it: an HTTP
        ``502`` for the router, a recorded ``provider_failed`` outcome for
        the scheduler.
    """
    connection = get_connection(session, user_id=user_id, connection_id=connection_id)
    if connection is None:
        raise ConnectionNotFoundError("unknown connection")

    state = consent_state(connection, now=now, warning_window_days=consent_warning_window_days)
    if state is ConsentState.EXPIRED:
        raise ConsentExpiredError("consent_expired")

    encrypted = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)
    if encrypted is None:
        raise CredentialsUnavailableError("unknown or inactive connection")

    credentials = cipher.decrypt(encrypted)
    since = now - timedelta(days=initial_history_days)

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

    mark_connection_synced(session, user_id=user_id, connection_id=connection_id, now=now)

    return SyncOutcome(
        accounts_synced=len(provider_accounts),
        transactions_synced=transactions_synced,
    )
