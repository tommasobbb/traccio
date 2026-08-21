"""Tests for the pure dashboard aggregation (``domain/dashboard``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import (
    CurrencySummary,
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
    summarize,
)


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


def test_empty_input_returns_no_summaries() -> None:
    assert summarize([]) == []


def test_single_currency_spending_and_income() -> None:
    """A spend and an income in the same currency split into the two totals."""
    members = [_tx(amount=-5000), _tx(amount=2000)]
    summaries = summarize(members)
    assert summaries == [
        CurrencySummary(
            currency="EUR",
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=2000, currency="EUR"),
            net=Money(amount=-3000, currency="EUR"),
            transaction_count=2,
        )
    ]


def test_transfer_member_counts_but_contributes_to_neither_total() -> None:
    """A transfer leg is neither spending nor income, but is still considered."""
    members = [_tx(amount=-5000), _tx(amount=-3000, role=TransactionRole.TRANSFER)]
    summaries = summarize(members)
    assert summaries == [
        CurrencySummary(
            currency="EUR",
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            net=Money(amount=-5000, currency="EUR"),
            transaction_count=2,
        )
    ]


def test_reimbursement_member_contributes_to_neither_total() -> None:
    """A reimbursement reduces a receivable — it is not income."""
    members = [_tx(amount=-5000), _tx(amount=3000, role=TransactionRole.REIMBURSEMENT)]
    summaries = summarize(members)
    assert summaries[0].income == Money(amount=0, currency="EUR")
    assert summaries[0].spending == Money(amount=5000, currency="EUR")
    assert summaries[0].transaction_count == 2


def test_rejected_member_contributes_to_neither_total() -> None:
    """A rejected movement never settled, so it counts zero regardless of role."""
    members = [_tx(amount=-5000), _tx(amount=-9999, status=TransactionStatus.REJECTED)]
    summaries = summarize(members)
    assert summaries[0].spending == Money(amount=5000, currency="EUR")
    assert summaries[0].transaction_count == 2


def test_advance_member_uses_supplied_share_not_the_full_amount() -> None:
    """This is the roadmap's M2 'done when': the dashboard shows the user's
    actual share, not the full advance amount."""
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE)  # €1000 flight for five
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}  # user's €200 share
    summaries = summarize([advance_tx], advance_shares=shares)
    assert summaries == [
        CurrencySummary(
            currency="EUR",
            spending=Money(amount=20000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            net=Money(amount=-20000, currency="EUR"),
            transaction_count=1,
        )
    ]


def test_two_currencies_never_summed_into_one_total() -> None:
    """No FX in Traccio: each currency gets its own summary, sorted by code."""
    members = [_tx(amount=-5000, currency="USD"), _tx(amount=-4000, currency="EUR")]
    summaries = summarize(members)
    assert [s.currency for s in summaries] == ["EUR", "USD"]
    assert summaries[0].spending == Money(amount=4000, currency="EUR")
    assert summaries[1].spending == Money(amount=5000, currency="USD")


def test_advance_member_missing_its_share_raises() -> None:
    """Propagated from effective_amount: an advance role always needs a share."""
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE)
    with pytest.raises(ValueError):
        summarize([advance_tx])
