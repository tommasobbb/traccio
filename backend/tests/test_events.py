"""Tests for the pure event aggregation (``domain/events``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``docs/engineering.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import (
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
    event_total,
)
from traccio.domain.events import REASON_MIXED_CURRENCY, EventError


def _tx(
    *,
    amount: int = -5000,
    currency: str = "EUR",
    role: TransactionRole = TransactionRole.PERSONAL,
    status: TransactionStatus = TransactionStatus.BOOKED,
) -> Transaction:
    """Build a synthetic transaction."""
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=amount, currency=currency),
        description="TEST MERCHANT 01",
        status=status,
        role=role,
        stable_key=f"TX-{uuid4()}",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_empty_event_has_no_total() -> None:
    """An event with no members has no currency and returns None."""
    assert event_total([]) is None


def test_sums_personal_effective_amounts() -> None:
    """A plain event totals the signed amounts of its personal members."""
    members = [_tx(amount=-5000), _tx(amount=-2500), _tx(amount=1000)]
    assert event_total(members) == Money(amount=-6500, currency="EUR")


def test_transfer_member_contributes_zero() -> None:
    """A transfer leg is not spending, so it does not move the total."""
    members = [_tx(amount=-5000), _tx(amount=-3000, role=TransactionRole.TRANSFER)]
    assert event_total(members) == Money(amount=-5000, currency="EUR")


def test_reimbursement_member_contributes_zero() -> None:
    """A reimbursement is neither income nor spending in the total."""
    members = [_tx(amount=-5000), _tx(amount=3000, role=TransactionRole.REIMBURSEMENT)]
    assert event_total(members) == Money(amount=-5000, currency="EUR")


def test_rejected_member_contributes_zero() -> None:
    """A rejected movement never settled, so it counts zero regardless of role."""
    members = [_tx(amount=-5000), _tx(amount=-9999, status=TransactionStatus.REJECTED)]
    assert event_total(members) == Money(amount=-5000, currency="EUR")


def test_advance_member_uses_supplied_share() -> None:
    """An advance contributes only the user's signed share, supplied by the caller."""
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE)  # €1000 flight for five
    members = [advance_tx]
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}  # user's €200 share
    assert event_total(members, advance_shares=shares) == Money(amount=-20000, currency="EUR")


def test_advance_and_personal_combine() -> None:
    """The advance share and personal spend add up to the real trip cost."""
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE)
    hotel = _tx(amount=-30000)
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}
    assert event_total([advance_tx, hotel], advance_shares=shares) == Money(
        amount=-50000, currency="EUR"
    )


def test_mixed_currency_members_cannot_be_totalled() -> None:
    """No FX in Traccio: an event spanning currencies has no single total."""
    members = [_tx(amount=-5000, currency="EUR"), _tx(amount=-4000, currency="USD")]
    with pytest.raises(EventError) as excinfo:
        event_total(members)
    assert excinfo.value.reason == REASON_MIXED_CURRENCY
