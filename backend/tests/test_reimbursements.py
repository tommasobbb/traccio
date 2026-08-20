"""Tests for the pure reimbursement/advance-state logic (``domain/advances``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import KeyStrategy, Money, Transaction, TransactionRole, TransactionStatus
from traccio.domain.advances import (
    REASON_CURRENCY_MISMATCH,
    REASON_NONPOSITIVE_AMOUNT,
    REASON_NOT_INCOMING,
    REASON_NOT_PERSONAL,
    REASON_REJECTED,
    ReimbursementError,
    derive_advance,
    validate_reimbursement,
)
from traccio.domain.enums import AdvanceStatus


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
        stable_key="TX-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def _eur(amount: int) -> Money:
    return Money(amount=amount, currency="EUR")


# --- derive_advance ---------------------------------------------------------


def test_open_when_nothing_reimbursed() -> None:
    """No reimbursements: outstanding equals the full receivable, status open."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=False)
    assert state.receivable == _eur(4000)
    assert state.reimbursed == _eur(0)
    assert state.outstanding == _eur(4000)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.OPEN
    # Spending share is just own_share, signed to match the outgoing spend.
    assert state.spending_share == _eur(-1000)


def test_partial_reimbursement_reduces_outstanding_and_stays_open() -> None:
    """A partial reimbursement lowers outstanding but does not settle."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(1500), written_off=False)
    assert state.outstanding == _eur(2500)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.OPEN
    assert state.spending_share == _eur(-1000)


def test_full_reimbursement_settles() -> None:
    """When reimbursements cover the receivable the advance is settled."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(4000), written_off=False)
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.SETTLED
    # Own share is still the only real spending.
    assert state.spending_share == _eur(-1000)


def test_over_reimbursement_is_flagged_not_absorbed() -> None:
    """Reimbursing beyond the receivable clamps outstanding and flags the excess."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(4500), written_off=False)
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(500)
    assert state.status is AdvanceStatus.SETTLED


def test_write_off_moves_outstanding_into_spending() -> None:
    """A written-off advance spends own_share plus whatever was never paid back."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(1500), written_off=True)
    assert state.status is AdvanceStatus.WRITTEN_OFF
    assert state.outstanding == _eur(2500)
    # Spending = own_share (1000) + outstanding (2500), signed negative.
    assert state.spending_share == _eur(-3500)


def test_write_off_with_no_reimbursements_spends_the_whole_amount() -> None:
    """Writing off an untouched advance makes the full amount spending."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=True)
    assert state.spending_share == _eur(-5000)


def test_derive_requires_matching_currencies() -> None:
    """own_share and reimbursed must share the transaction's currency."""
    with pytest.raises(ValueError, match="currency"):
        derive_advance(
            _tx(currency="EUR"), _eur(1000), Money(amount=0, currency="USD"), written_off=False
        )


# --- validate_reimbursement -------------------------------------------------


def test_validate_accepts_a_clean_cash_reimbursement() -> None:
    """A positive cash amount in the advance currency validates."""
    validate_reimbursement(_eur(1000), "EUR", transaction=None)  # does not raise


def test_validate_accepts_a_clean_linked_transaction() -> None:
    """A personal, incoming, same-currency transaction may be linked."""
    validate_reimbursement(_eur(1000), "EUR", transaction=_tx(amount=2000))  # does not raise


def test_validate_rejects_nonpositive_amount() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(_eur(0), "EUR", transaction=None)
    assert exc.value.reason == REASON_NONPOSITIVE_AMOUNT


def test_validate_rejects_currency_mismatch() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(Money(amount=1000, currency="USD"), "EUR", transaction=None)
    assert exc.value.reason == REASON_CURRENCY_MISMATCH


def test_validate_rejects_outgoing_linked_transaction() -> None:
    """A linked transaction must be incoming (money received)."""
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(_eur(1000), "EUR", transaction=_tx(amount=-2000))
    assert exc.value.reason == REASON_NOT_INCOMING


def test_validate_rejects_non_personal_linked_transaction() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(
            _eur(1000), "EUR", transaction=_tx(amount=2000, role=TransactionRole.TRANSFER)
        )
    assert exc.value.reason == REASON_NOT_PERSONAL


def test_validate_rejects_rejected_linked_transaction() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(
            _eur(1000), "EUR", transaction=_tx(amount=2000, status=TransactionStatus.REJECTED)
        )
    assert exc.value.reason == REASON_REJECTED
