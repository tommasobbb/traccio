"""Tests for ``services.advances.spending_shares``.

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``docs/engineering.md``.
"""

from uuid import UUID, uuid4

from traccio.domain import (
    Advance,
    AdvanceStatus,
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
)
from traccio.services.advances import spending_shares


def _tx(
    *,
    amount: int = -100000,
    currency: str = "EUR",
    role: TransactionRole = TransactionRole.ADVANCE,
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


def _advance(
    *, transaction_id: UUID, own_share: int, currency: str = "EUR", status: AdvanceStatus
) -> Advance:
    """Build a synthetic advance linked to ``transaction_id``."""
    return Advance(
        user_id=uuid4(),
        transaction_id=transaction_id,
        own_share=Money(amount=own_share, currency=currency),
        status=status,
    )


def test_non_advance_transactions_are_absent_from_the_result() -> None:
    """A personal or transfer transaction never needs a resolved share."""
    personal = _tx(role=TransactionRole.PERSONAL)
    transfer = _tx(role=TransactionRole.TRANSFER)
    shares = spending_shares([personal, transfer], advance_by_tx={}, reimbursed={})
    assert shares == {}


def test_advance_with_no_linked_row_is_absent() -> None:
    """A stray advance-role transaction with no matching Advance is omitted,
    not an error — see the module docstring."""
    advance_tx = _tx()
    shares = spending_shares([advance_tx], advance_by_tx={}, reimbursed={})
    assert shares == {}


def test_open_advance_uses_own_share() -> None:
    """With no reimbursements yet, the share is exactly the declared own_share."""
    advance_tx = _tx(amount=-100000)  # €1000 flight for five
    advance = _advance(transaction_id=advance_tx.id, own_share=20000, status=AdvanceStatus.OPEN)
    shares = spending_shares([advance_tx], advance_by_tx={advance_tx.id: advance}, reimbursed={})
    assert shares == {advance_tx.id: Money(amount=-20000, currency="EUR")}


def test_advance_absent_from_reimbursed_mapping_is_treated_as_zero() -> None:
    """An advance id missing from `reimbursed` means nothing received yet."""
    advance_tx = _tx(amount=-100000)
    advance = _advance(transaction_id=advance_tx.id, own_share=20000, status=AdvanceStatus.OPEN)
    shares = spending_shares([advance_tx], advance_by_tx={advance_tx.id: advance}, reimbursed={})
    assert shares == {advance_tx.id: Money(amount=-20000, currency="EUR")}


def test_written_off_advance_moves_outstanding_into_the_share() -> None:
    """A write-off means the outstanding amount was never paid back — it is
    real spending, added on top of own_share (see domain/advances.py)."""
    advance_tx = _tx(amount=-100000)
    advance = _advance(
        transaction_id=advance_tx.id, own_share=20000, status=AdvanceStatus.WRITTEN_OFF
    )
    shares = spending_shares([advance_tx], advance_by_tx={advance_tx.id: advance}, reimbursed={})
    # Nothing reimbursed: the full €800 receivable is written off on top of the
    # €200 own_share, for a €1000 total spend (the whole transaction).
    assert shares == {advance_tx.id: Money(amount=-100000, currency="EUR")}


def test_multiple_advances_resolve_independently() -> None:
    """Each advance transaction's share is resolved from its own linked row."""
    flight = _tx(amount=-100000)
    dinner = _tx(amount=-8000)
    flight_advance = _advance(transaction_id=flight.id, own_share=20000, status=AdvanceStatus.OPEN)
    dinner_advance = _advance(transaction_id=dinner.id, own_share=4000, status=AdvanceStatus.OPEN)
    shares = spending_shares(
        [flight, dinner],
        advance_by_tx={flight.id: flight_advance, dinner.id: dinner_advance},
        reimbursed={},
    )
    assert shares == {
        flight.id: Money(amount=-20000, currency="EUR"),
        dinner.id: Money(amount=-4000, currency="EUR"),
    }
