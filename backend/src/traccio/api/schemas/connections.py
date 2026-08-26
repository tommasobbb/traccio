"""Request and response schemas for the connections endpoints.

None of these carry secret material: the consent secret (``session_id``) is
encrypted at rest and never returned by any endpoint (``.claude/rules/data-safety.md``).
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.consent import consent_state, days_until_expiry
from traccio.domain.enums import ConnectionStatus, ConsentState
from traccio.domain.models import Connection
from traccio.providers.base import Institution


class StartConnectionRequest(BaseModel):
    """Request to begin authorizing a bank connection.

    Attributes
    ----------
    institution : str
        The bank's provider-scoped identifier (Enable Banking ASPSP ``name``).
    country : str
        ISO 3166-1 alpha-2 country of the bank.
    """

    institution: str
    country: str


class StartConnectionResponse(BaseModel):
    """The started authorization: where to send the user.

    Attributes
    ----------
    connection_id : UUID
        The pending connection created for this authorization.
    authorization_url : str
        The bank authorization URL to open in the system browser.
    """

    connection_id: UUID
    authorization_url: str


class InstitutionResponse(BaseModel):
    """One bank the caller can authorize, as returned to the client.

    Attributes
    ----------
    name : str
        The provider-scoped institution identifier — pass this straight back
        as ``StartConnectionRequest.institution``.
    country : str
        ISO 3166-1 alpha-2 country the institution is offered in.
    """

    name: str
    country: str

    @classmethod
    def from_domain(cls, institution: Institution) -> "InstitutionResponse":
        """Project a provider :class:`~traccio.providers.base.Institution`."""
        return cls(name=institution.name, country=institution.country)


class InstitutionsResponse(BaseModel):
    """Envelope for the institution list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    institutions : list[InstitutionResponse]
        The institutions offered in the requested country, in the provider's
        own order.
    """

    institutions: list[InstitutionResponse]


class SyncResponse(BaseModel):
    """The outcome of syncing a connection.

    Only counts are returned, never account or transaction contents
    (``.claude/rules/data-safety.md``); the data itself is read back via the
    resource endpoints (e.g. ``GET /accounts``).

    Attributes
    ----------
    accounts_synced : int
        How many accounts were discovered and persisted (inserted or updated).
    transactions_synced : int
        How many transactions were fetched and persisted across those accounts
        (inserted, or updated in place while still pending).
    """

    accounts_synced: int
    transactions_synced: int


class ConnectionResponse(BaseModel):
    """One connection as returned to the client.

    A narrow projection of :class:`~traccio.domain.models.Connection`. It
    carries no secret material by construction: the consent secret and the
    anti-CSRF ``auth_state`` live only on the ORM row, never on the domain model
    this is built from (see ``.claude/rules/data-safety.md``). ``user_id`` is
    implied by the caller and omitted.

    Attributes
    ----------
    id : UUID
        Stable connection identifier.
    provider : str
        Adapter that produced the connection (e.g. ``"enable_banking"``).
    institution_name : str
        Human-readable bank name for display.
    status : ConnectionStatus
        Consent lifecycle state, as last reported by the provider. See
        ``consent_state`` for the field the client should actually render.
    consent_state : ConsentState
        The *actual*, time-aware state — ``status`` re-read against
        ``expires_at`` and the current time by
        :func:`~traccio.domain.consent.consent_state`. Derived here, once; the
        client renders this and never recomputes it from ``expires_at``.
    days_until_expiry : int or None
        Whole days until ``expires_at`` (negative once lapsed), or ``None`` when
        ``expires_at`` is unset. A display figure — ``consent_state`` is the
        authoritative expired/not-expired call.
    expires_at : datetime or None
        Consent expiry, as reported by the provider; ``None`` while pending.
    created_at : datetime
        When the connection was created.
    last_synced_at : datetime or None
        When a sync last ran against this connection; ``None`` until the first
        sync. A display figure only.
    background_sync_enabled : bool
        Whether the background scheduler is running at all
        (``Settings.background_sync_enabled``, ADR 0010). When ``False``,
        ``sync_budget_remaining`` and ``next_sync_at`` are both ``None`` —
        they have nothing meaningful to say if nothing is scheduling syncs.
    sync_budget_remaining : int or None
        How many more background sync runs this connection may have in the
        current rolling 24h, or ``None`` when
        ``background_sync_enabled`` is ``False``. Derived fresh on every
        read from :func:`~traccio.db.repositories.count_recent_sync_runs`,
        never stored (ADR 0006's discipline).
    next_sync_at : datetime or None
        When this connection is next expected to become eligible for a
        background sync (:func:`~traccio.domain.sync_schedule.next_sync_eligible_at`),
        or ``None`` when ``background_sync_enabled`` is ``False``, the
        connection is already due (the next tick will sync it), or its
        consent needs the user to re-authorize rather than time to pass.
    """

    id: UUID
    provider: str
    institution_name: str
    status: ConnectionStatus
    consent_state: ConsentState
    days_until_expiry: int | None
    expires_at: datetime | None
    created_at: datetime
    last_synced_at: datetime | None
    background_sync_enabled: bool
    sync_budget_remaining: int | None
    next_sync_at: datetime | None

    @classmethod
    def from_domain(
        cls,
        connection: Connection,
        *,
        now: datetime,
        warning_window_days: int,
        background_sync_enabled: bool,
        sync_budget_remaining: int | None,
        next_sync_at: datetime | None,
    ) -> "ConnectionResponse":
        """Project a domain :class:`~traccio.domain.models.Connection`.

        Parameters
        ----------
        connection : Connection
            The domain connection to project.
        now : datetime
            The current time, used to derive ``consent_state`` and
            ``days_until_expiry``.
        warning_window_days : int
            How many days before expiry count as "expiring soon" (see
            ``Settings.consent_warning_window_days``).
        background_sync_enabled : bool
            Whether the scheduler is running at all
            (``Settings.background_sync_enabled``).
        sync_budget_remaining : int or None
            Pre-computed remaining budget for this connection, or ``None``
            when the scheduler is disabled. The caller (the router) computes
            this — it needs a database query
            (``count_recent_sync_runs``) this schema module has no business
            making.
        next_sync_at : datetime or None
            Pre-computed next-eligible time for this connection, or ``None``.
            Same reasoning as ``sync_budget_remaining``.

        Returns
        -------
        ConnectionResponse
            The narrowed, client-facing view of ``connection``.
        """
        return cls(
            id=connection.id,
            provider=connection.provider,
            institution_name=connection.institution_name,
            status=connection.status,
            consent_state=consent_state(
                connection, now=now, warning_window_days=warning_window_days
            ),
            days_until_expiry=days_until_expiry(connection, now=now),
            expires_at=connection.expires_at,
            created_at=connection.created_at,
            last_synced_at=connection.last_synced_at,
            background_sync_enabled=background_sync_enabled,
            sync_budget_remaining=sync_budget_remaining,
            next_sync_at=next_sync_at,
        )


class ConnectionsResponse(BaseModel):
    """Envelope for the connection list.

    A wrapper object rather than a bare array leaves room for pagination or
    metadata later without breaking the generated Swift client.

    Attributes
    ----------
    connections : list[ConnectionResponse]
        The caller's connections, oldest first.
    """

    connections: list[ConnectionResponse]
