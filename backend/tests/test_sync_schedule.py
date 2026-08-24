"""Tests for the pure background-sync decision (``domain/sync_schedule``).

Pure unit tests: no database, no network, no wall clock — ``now`` is always
passed in. Fixtures use synthetic values only (see
``.claude/rules/data-safety.md``). Pays special attention to the exact
boundaries (budget exhausted at the count, interval reached exactly) —
``tasks/backlog.md`` flagged that ``consent_state``'s own boundary went
untested for a while; this file does not repeat that gap.
"""

from datetime import UTC, datetime, timedelta

import pytest

from traccio.domain import ConsentState, SyncDecision, next_sync_eligible_at, sync_decision
from traccio.domain.enums import SyncRunOutcome

_NOW = datetime(2026, 8, 24, 12, 0, 0, tzinfo=UTC)
_BUDGET_PER_DAY = 4
_MIN_INTERVAL_HOURS = 6


def _decide(
    *,
    consent_state: ConsentState = ConsentState.ACTIVE,
    runs_last_24h: int = 0,
    last_synced_at: datetime | None = None,
    now: datetime = _NOW,
    budget_per_day: int = _BUDGET_PER_DAY,
    min_interval_hours: int = _MIN_INTERVAL_HOURS,
) -> SyncDecision:
    return sync_decision(
        consent_state=consent_state,
        runs_last_24h=runs_last_24h,
        last_synced_at=last_synced_at,
        now=now,
        budget_per_day=budget_per_day,
        min_interval_hours=min_interval_hours,
    )


def test_due_when_active_with_budget_and_no_prior_sync() -> None:
    decision = _decide()
    assert decision.due is True
    assert decision.skip_reason is None


def test_due_when_expiring_soon_still_syncable() -> None:
    """A close-to-expiry consent is still usable — only EXPIRED and friends
    are not (see ``docs/openbanking.md``: expiry warnings exist so the user
    re-authorizes before syncing actually stops working)."""
    assert _decide(consent_state=ConsentState.EXPIRING_SOON).due is True


@pytest.mark.parametrize(
    "state",
    [ConsentState.PENDING, ConsentState.EXPIRED, ConsentState.REVOKED, ConsentState.ERROR],
)
def test_skipped_for_every_non_syncable_consent_state(state: ConsentState) -> None:
    decision = _decide(consent_state=state)
    assert decision.due is False
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_CONSENT


def test_due_one_run_under_budget() -> None:
    assert _decide(runs_last_24h=_BUDGET_PER_DAY - 1).due is True


def test_skipped_exactly_at_budget() -> None:
    """The boundary: runs_last_24h == budget_per_day already refuses — the
    budget is a hard ceiling, not "at least one more allowed"."""
    decision = _decide(runs_last_24h=_BUDGET_PER_DAY)
    assert decision.due is False
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_BUDGET


def test_skipped_over_budget() -> None:
    decision = _decide(runs_last_24h=_BUDGET_PER_DAY + 3)
    assert decision.due is False
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_BUDGET


def test_due_when_never_synced_regardless_of_interval() -> None:
    assert _decide(last_synced_at=None).due is True


def test_due_exactly_at_the_interval_boundary() -> None:
    """The boundary: exactly min_interval_hours since the last sync is
    already due — the gate only blocks *less* than the interval."""
    decision = _decide(last_synced_at=_NOW - timedelta(hours=_MIN_INTERVAL_HOURS))
    assert decision.due is True


def test_skipped_one_second_short_of_the_interval() -> None:
    decision = _decide(
        last_synced_at=_NOW - timedelta(hours=_MIN_INTERVAL_HOURS) + timedelta(seconds=1)
    )
    assert decision.due is False
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_INTERVAL


def test_due_just_past_the_interval() -> None:
    decision = _decide(
        last_synced_at=_NOW - timedelta(hours=_MIN_INTERVAL_HOURS) - timedelta(seconds=1)
    )
    assert decision.due is True


def test_naive_last_synced_at_is_read_as_utc() -> None:
    """SQLite discards tzinfo on read-back (the same quirk
    ``domain/consent.py`` guards against for ``expires_at``); a naive
    timestamp must behave identically to its UTC-aware equivalent."""
    aware = _decide(last_synced_at=_NOW - timedelta(hours=1))
    naive = _decide(last_synced_at=(_NOW - timedelta(hours=1)).replace(tzinfo=None))
    assert aware == naive
    assert naive.due is False
    assert naive.skip_reason is SyncRunOutcome.SKIPPED_INTERVAL


def test_consent_gate_wins_over_budget_when_both_would_fail() -> None:
    """Only one skip_reason is ever reported — the first gate that fails,
    consent before budget before interval."""
    decision = _decide(
        consent_state=ConsentState.EXPIRED,
        runs_last_24h=_BUDGET_PER_DAY + 10,
        last_synced_at=_NOW,
    )
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_CONSENT


def test_budget_gate_wins_over_interval_when_both_would_fail() -> None:
    decision = _decide(runs_last_24h=_BUDGET_PER_DAY, last_synced_at=_NOW)
    assert decision.skip_reason is SyncRunOutcome.SKIPPED_BUDGET


# --- next_sync_eligible_at ---


def _next_eligible(
    *,
    consent_state: ConsentState = ConsentState.ACTIVE,
    runs_last_24h: int = 0,
    oldest_run_started_at: datetime | None = None,
    last_synced_at: datetime | None = None,
    now: datetime = _NOW,
    budget_per_day: int = _BUDGET_PER_DAY,
    min_interval_hours: int = _MIN_INTERVAL_HOURS,
) -> datetime | None:
    return next_sync_eligible_at(
        consent_state=consent_state,
        runs_last_24h=runs_last_24h,
        oldest_run_started_at=oldest_run_started_at,
        last_synced_at=last_synced_at,
        now=now,
        budget_per_day=budget_per_day,
        min_interval_hours=min_interval_hours,
    )


def test_next_eligible_is_none_when_already_due() -> None:
    """Nothing meaningful to show — the next tick will just sync it."""
    assert _next_eligible() is None


def test_next_eligible_is_none_when_blocked_on_consent() -> None:
    """Re-authorization, not time, is what unblocks this — never a timestamp."""
    assert _next_eligible(consent_state=ConsentState.EXPIRED, runs_last_24h=99) is None


def test_next_eligible_is_last_synced_at_plus_the_interval() -> None:
    last_synced_at = _NOW - timedelta(hours=1)
    result = _next_eligible(last_synced_at=last_synced_at)
    assert result == last_synced_at + timedelta(hours=_MIN_INTERVAL_HOURS)


def test_next_eligible_is_the_oldest_run_plus_24h_when_budget_blocked() -> None:
    oldest = _NOW - timedelta(hours=20)
    result = _next_eligible(runs_last_24h=_BUDGET_PER_DAY, oldest_run_started_at=oldest)
    assert result == oldest + timedelta(hours=24)


def test_next_eligible_is_none_for_budget_block_with_no_recorded_oldest_run() -> None:
    """Defensive: shouldn't happen if runs_last_24h > 0, but stay honest about
    not knowing rather than guessing."""
    result = _next_eligible(runs_last_24h=_BUDGET_PER_DAY, oldest_run_started_at=None)
    assert result is None


def test_next_eligible_agrees_with_sync_decision_on_which_gate_blocks() -> None:
    """Budget wins over interval, same order as sync_decision — proven by
    reusing sync_decision internally rather than re-deriving the order."""
    oldest = _NOW - timedelta(hours=20)
    result = _next_eligible(
        runs_last_24h=_BUDGET_PER_DAY, oldest_run_started_at=oldest, last_synced_at=_NOW
    )
    # If interval had won instead, this would equal _NOW + min_interval_hours.
    assert result == oldest + timedelta(hours=24)
