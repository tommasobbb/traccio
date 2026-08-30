"""Tests for the ``effective_amount`` derivation.

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented references) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import (
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
    effective_amount,
)


def _tx(
    *,
    role: TransactionRole = TransactionRole.PERSONAL,
    status: TransactionStatus = TransactionStatus.BOOKED,
    amount: int = -1234,
    currency: str = "EUR",
) -> Transaction:
    """Build a synthetic transaction with the given role and status."""
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


def test_personal_counts_the_full_amount() -> None:
    """A personal transaction's effective amount is its full amount."""
    assert effective_amount(_tx(role=TransactionRole.PERSONAL)) == Money(
        amount=-1234, currency="EUR"
    )


def test_transfer_counts_zero() -> None:
    """A transfer is neither income nor spending: effective amount is zero."""
    assert effective_amount(_tx(role=TransactionRole.TRANSFER)) == Money(amount=0, currency="EUR")


def test_reimbursement_counts_zero() -> None:
    """A reimbursement reduces a receivable, it is not income: zero."""
    assert effective_amount(_tx(role=TransactionRole.REIMBURSEMENT)) == Money(
        amount=0, currency="EUR"
    )


def test_funding_counts_zero() -> None:
    """A funding leg is only plumbing for a payment made elsewhere: zero.

    The real spending is the funded leg, which stays ``personal`` and keeps its
    full amount — see ``TransferKind.FUNDED_PAYMENT``.
    """
    assert effective_amount(_tx(role=TransactionRole.FUNDING, amount=-1290)) == Money(
        amount=0, currency="EUR"
    )


@pytest.mark.parametrize(
    "role",
    [TransactionRole.PERSONAL, TransactionRole.TRANSFER, TransactionRole.FUNDING],
)
def test_rejected_counts_zero_regardless_of_role(role: TransactionRole) -> None:
    """A rejected movement never settled, so it contributes zero for any role."""
    tx = _tx(role=role, status=TransactionStatus.REJECTED)

    assert effective_amount(tx) == Money(amount=0, currency="EUR")


def test_advance_counts_only_the_declared_own_share() -> None:
    """An advance counts only the user's own share, in the same currency."""
    tx = _tx(role=TransactionRole.ADVANCE, amount=-5000)

    result = effective_amount(tx, advance_own_share=Money(amount=-1000, currency="EUR"))

    assert result == Money(amount=-1000, currency="EUR")


def test_advance_without_own_share_raises() -> None:
    """An advance with no own_share cannot be derived and raises."""
    with pytest.raises(ValueError, match="own_share"):
        effective_amount(_tx(role=TransactionRole.ADVANCE))


def test_advance_with_mismatched_currency_raises() -> None:
    """An own_share in a different currency than the transaction raises."""
    tx = _tx(role=TransactionRole.ADVANCE, currency="EUR")

    with pytest.raises(ValueError, match="currency"):
        effective_amount(tx, advance_own_share=Money(amount=-1000, currency="USD"))


def test_currency_is_preserved_for_a_zeroed_role() -> None:
    """A zeroed role keeps the transaction's own currency on the result."""
    result = effective_amount(_tx(role=TransactionRole.TRANSFER, currency="GBP"))

    assert result.currency == "GBP"
    assert result.amount == 0
