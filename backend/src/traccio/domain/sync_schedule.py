"""Derive whether one connection is due for a background sync, right now.

Sibling to :func:`~traccio.domain.consent.consent_state` (ADR 0006) and
:func:`~traccio.domain.categories.effective_category`: computed fresh on every
scheduler tick from the clock and a connection's recent
:class:`~traccio.domain.models.SyncRun` history, never stored. No scheduler
state beyond what is already on record is needed to answer "is this
connection due" — the same reasoning that lets ``consent_state`` need no
background job to stay true.

The background fetch budget (``docs/openbanking.md``: "~4 background fetches
per day per consent") is read here as *runs*, not raw provider HTTP calls —
see :func:`~traccio.db.repositories.count_recent_sync_runs`'s docstring for
why. It is a hard product constraint, not a tuning parameter: this function
refuses rather than lets the caller retry into a throttle.

This module imports nothing outside ``domain/``.
"""

from datetime import UTC, datetime, timedelta

from pydantic import BaseModel, ConfigDict

from traccio.domain.enums import ConsentState, SyncRunOutcome


def _as_aware_utc(value: datetime) -> datetime:
    """Return ``value``, defaulting a naive value to UTC.

    SQLite (used in dev and by the test suite; PostgreSQL is the eventual
    production target) discards timezone info on a ``DateTime(timezone=True)``
    column, so a value stored as UTC comes back naive. Every timestamp in this
    system is UTC (root ``CLAUDE.md``), so treating a naive value as UTC is the
    correct reading, not a guess — the same guard
    :func:`~traccio.domain.consent._expiry_as_aware_utc` applies to
    ``expires_at``.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


# A consent is syncable only in these two derived states. Anything else
# (pending, expiring past the point of no return handled elsewhere, expired,
# revoked, error) cannot produce a successful sync, so there is no point
# spending a budget slot or an attempt on it.
_SYNCABLE_CONSENT_STATES = frozenset({ConsentState.ACTIVE, ConsentState.EXPIRING_SOON})


class SyncDecision(BaseModel):
    """Whether a connection is due for a background sync right now.

    Attributes
    ----------
    due : bool
        ``True`` when the scheduler should actually call
        ``services/sync.py::sync_connection``.
    skip_reason : SyncRunOutcome or None
        The ``skipped_*`` outcome to record when ``due`` is ``False``
        (:attr:`~traccio.domain.enums.SyncRunOutcome.SKIPPED_CONSENT`,
        :attr:`~traccio.domain.enums.SyncRunOutcome.SKIPPED_BUDGET`, or
        :attr:`~traccio.domain.enums.SyncRunOutcome.SKIPPED_INTERVAL`).
        ``None`` when ``due`` is ``True``.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    due: bool
    skip_reason: SyncRunOutcome | None = None


def sync_decision(
    *,
    consent_state: ConsentState,
    runs_last_24h: int,
    last_synced_at: datetime | None,
    now: datetime,
    budget_per_day: int,
    min_interval_hours: int,
) -> SyncDecision:
    """Decide whether a background sync should run for one connection now.

    Three gates, checked in order — the first one that fails wins, so only
    one ``skip_reason`` is ever reported even when several would apply:

    1. **Consent.** Only :attr:`~traccio.domain.enums.ConsentState.ACTIVE` or
       :attr:`~traccio.domain.enums.ConsentState.EXPIRING_SOON` are syncable.
       A lapsed, pending, revoked, or errored consent cannot produce a
       successful sync, so it is skipped before spending any budget on it.
    2. **Budget.** ``runs_last_24h`` already at or above ``budget_per_day``
       refuses — this is the hard constraint
       (``docs/openbanking.md``), not a preference.
    3. **Interval.** A connection synced (by any trigger) more recently than
       ``min_interval_hours`` ago is skipped even with budget left, so a
       user-triggered sync moments before a scheduler tick does not also
       burn a background slot for no new data.

    Parameters
    ----------
    consent_state : ConsentState
        The connection's derived state, from
        :func:`~traccio.domain.consent.consent_state`.
    runs_last_24h : int
        How many sync runs (any outcome, any trigger) this connection has on
        record in the last rolling 24h — from
        :func:`~traccio.db.repositories.count_recent_sync_runs`.
    last_synced_at : datetime or None
        When this connection last *completed* a sync (``Connection.last_synced_at``,
        stamped only on success — see ``db/repositories.py::mark_connection_synced``),
        or ``None`` if it never has.
    now : datetime
        The current time, timezone-aware. Passed in rather than read
        internally so this stays testable with no clock.
    budget_per_day : int
        Maximum sync runs allowed per rolling 24h
        (``Settings.background_sync_budget_per_day``).
    min_interval_hours : int
        Minimum whole hours between two syncs of the same connection
        (``Settings.sync_min_interval_hours``).

    Returns
    -------
    SyncDecision
        Whether to sync now, and if not, why.
    """
    if consent_state not in _SYNCABLE_CONSENT_STATES:
        return SyncDecision(due=False, skip_reason=SyncRunOutcome.SKIPPED_CONSENT)

    if runs_last_24h >= budget_per_day:
        return SyncDecision(due=False, skip_reason=SyncRunOutcome.SKIPPED_BUDGET)

    if last_synced_at is not None and (now - _as_aware_utc(last_synced_at)) < timedelta(
        hours=min_interval_hours
    ):
        return SyncDecision(due=False, skip_reason=SyncRunOutcome.SKIPPED_INTERVAL)

    return SyncDecision(due=True)


def next_sync_eligible_at(
    *,
    consent_state: ConsentState,
    runs_last_24h: int,
    oldest_run_started_at: datetime | None,
    last_synced_at: datetime | None,
    now: datetime,
    budget_per_day: int,
    min_interval_hours: int,
) -> datetime | None:
    """Return when this connection next becomes eligible for a background sync.

    A display figure for the client ("prossima sync tra Xh") — derived fresh
    on every call from :func:`sync_decision`, never stored, same discipline
    as everything else in this module. Reuses ``sync_decision`` rather than
    re-checking the gates, so the two can never disagree about *why* a
    connection isn't due right now.

    ``None`` means one of two different things, which is fine for a display
    figure but worth knowing: either the connection is already due (the next
    scheduler tick will sync it, so there is no meaningful "in how long" to
    show), or its consent needs the user to re-authorize, which is not a
    matter of time at all.

    Parameters
    ----------
    consent_state, runs_last_24h, last_synced_at, now, budget_per_day,
    min_interval_hours
        Forwarded to :func:`sync_decision` — see its docstring.
    oldest_run_started_at : datetime or None
        The earliest ``started_at`` among the runs counted in
        ``runs_last_24h`` (:func:`~traccio.db.repositories.oldest_recent_sync_run_started_at`).
        Only consulted when the budget gate is what's blocking: once that run
        ages past 24h old, the rolling count drops and a slot frees up
        (assuming nothing else fills it first — this is an estimate, not a
        promise, since a new run recorded before then would push the window
        forward again).

    Returns
    -------
    datetime or None
        When a slot is expected to open, or ``None`` (already due, or
        blocked on re-authorization rather than time).
    """
    decision = sync_decision(
        consent_state=consent_state,
        runs_last_24h=runs_last_24h,
        last_synced_at=last_synced_at,
        now=now,
        budget_per_day=budget_per_day,
        min_interval_hours=min_interval_hours,
    )
    if decision.due or decision.skip_reason is SyncRunOutcome.SKIPPED_CONSENT:
        return None
    if decision.skip_reason is SyncRunOutcome.SKIPPED_INTERVAL:
        # sync_decision only returns this when last_synced_at is not None.
        assert last_synced_at is not None
        return _as_aware_utc(last_synced_at) + timedelta(hours=min_interval_hours)
    if decision.skip_reason is SyncRunOutcome.SKIPPED_BUDGET:
        if oldest_run_started_at is None:
            return None
        return _as_aware_utc(oldest_run_started_at) + timedelta(hours=24)
    return None
