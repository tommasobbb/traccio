"""Tests for the pure advance arithmetic and validation (``domain/advances``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import KeyStrategy, Money, Transaction, TransactionRole, TransactionStatus
from traccio.domain.advances import (
    REASON_CURRENCY_MISMATCH,
    REASON_NOT_OUTGOING,
    REASON_NOT_PERSONAL,
    REASON_REJECTED,
    REASON_SHARE_OUT_OF_RANGE,
    AdvanceError,
    advance_spending_share,
    outstanding,
    receivable,
    validate_advance,
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
        stable_key="TX-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_receivable_is_amount_magnitude_minus_own_share() -> None:
    """Receivable is a positive magnitude: |amount| - own_share."""
    tx = _tx(amount=-5000)
    assert receivable(tx, Money(amount=1000, currency="EUR")) == Money(amount=4000, currency="EUR")


def test_receivable_currency_must_match() -> None:
    """A share in a different currency cannot form a receivable."""
    with pytest.raises(ValueError, match="currency"):
        receivable(_tx(currency="EUR"), Money(amount=1000, currency="USD"))


def test_outstanding_subtracts_reimbursed() -> None:
    """Outstanding is receivable minus what has been paid back."""
    result = outstanding(Money(amount=4000, currency="EUR"), Money(amount=1500, currency="EUR"))
    assert result == Money(amount=2500, currency="EUR")


def test_outstanding_equals_receivable_when_nothing_reimbursed() -> None:
    """With no reimbursements outstanding equals the receivable."""
    receivable_amount = Money(amount=4000, currency="EUR")
    assert outstanding(receivable_amount, Money(amount=0, currency="EUR")) == receivable_amount


def test_spending_share_is_signed_to_match_the_transaction() -> None:
    """The signed share fed to effective_amount is negative for an outgoing spend."""
    tx = _tx(amount=-5000)
    assert advance_spending_share(tx, Money(amount=1000, currency="EUR")) == Money(
        amount=-1000, currency="EUR"
    )


def test_validate_accepts_a_clean_advance() -> None:
    """A personal, outgoing transaction with an in-range share validates."""
    validate_advance(_tx(amount=-5000), Money(amount=1000, currency="EUR"))  # does not raise


def test_validate_accepts_own_share_equal_to_full_amount() -> None:
    """own_share may equal |amount| (receivable zero)."""
    validate_advance(_tx(amount=-5000), Money(amount=5000, currency="EUR"))  # does not raise


def test_validate_rejects_rejected_transaction() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(status=TransactionStatus.REJECTED), Money(amount=1000, currency="EUR"))
    assert exc.value.reason == REASON_REJECTED


def test_validate_rejects_non_personal_transaction() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(role=TransactionRole.TRANSFER), Money(amount=1000, currency="EUR"))
    assert exc.value.reason == REASON_NOT_PERSONAL


def test_validate_rejects_incoming_transaction() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(amount=5000), Money(amount=1000, currency="EUR"))
    assert exc.value.reason == REASON_NOT_OUTGOING


def test_validate_rejects_mismatched_currency() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(currency="EUR"), Money(amount=1000, currency="USD"))
    assert exc.value.reason == REASON_CURRENCY_MISMATCH


def test_validate_rejects_share_over_amount() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(amount=-5000), Money(amount=6000, currency="EUR"))
    assert exc.value.reason == REASON_SHARE_OUT_OF_RANGE


def test_validate_rejects_negative_share() -> None:
    with pytest.raises(AdvanceError) as exc:
        validate_advance(_tx(amount=-5000), Money(amount=-1, currency="EUR"))
    assert exc.value.reason == REASON_SHARE_OUT_OF_RANGE
