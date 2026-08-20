"""Tests for transfer detection (the pure matcher in ``services/transfers``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented references) — see ``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from traccio.domain import KeyStrategy, Money, Transaction, TransactionRole, TransactionStatus
from traccio.services.transfers import detect_transfers

_BASE = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    *,
    account_id: UUID,
    amount: int,
    currency: str = "EUR",
    booked_at: datetime | None = _BASE,
    value_date: datetime | None = None,
    role: TransactionRole = TransactionRole.PERSONAL,
    status: TransactionStatus = TransactionStatus.BOOKED,
) -> Transaction:
    """Build a synthetic transaction on ``account_id``."""
    return Transaction(
        id=uuid4(),
        user_id=uuid4(),
        account_id=account_id,
        money=Money(amount=amount, currency=currency),
        booked_at=booked_at,
        value_date=value_date,
        description="TEST MERCHANT 01",
        status=status,
        role=role,
        stable_key=uuid4().hex,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_detects_a_clean_opposite_leg_pair() -> None:
    """Opposite signs, same currency, different accounts, same day -> one match."""
    a, b = uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000)
    inc = _tx(account_id=b, amount=50000)

    [suggestion] = detect_transfers([out, inc])

    assert suggestion.outgoing_transaction_id == out.id
    assert suggestion.incoming_transaction_id == inc.id
    assert suggestion.currency == "EUR"
    assert suggestion.amount_delta == 0
    assert suggestion.day_gap == 0


def test_amount_tolerance_boundary() -> None:
    """A fee within tolerance still matches; beyond it does not."""
    a, b = uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000)
    inc = _tx(account_id=b, amount=49950)  # 50 cents less (a fee)

    assert len(detect_transfers([out, inc], amount_tolerance_cents=100)) == 1
    assert detect_transfers([out, inc], amount_tolerance_cents=10) == []


def test_window_boundary() -> None:
    """Legs within the window match; beyond it they do not."""
    a, b = uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000, booked_at=_BASE)
    inc = _tx(account_id=b, amount=50000, booked_at=_BASE + timedelta(days=3))

    assert len(detect_transfers([out, inc], window_days=4)) == 1
    assert detect_transfers([out, inc], window_days=2) == []


def test_same_account_is_not_a_transfer() -> None:
    """Both legs on one account cannot be a transfer between accounts."""
    a = uuid4()
    assert (
        detect_transfers([_tx(account_id=a, amount=-50000), _tx(account_id=a, amount=50000)]) == []
    )


def test_different_currency_does_not_match() -> None:
    """A transfer is single-currency; differing currencies do not pair."""
    a, b = uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000, currency="EUR")
    inc = _tx(account_id=b, amount=50000, currency="USD")

    assert detect_transfers([out, inc]) == []


def test_same_sign_does_not_match() -> None:
    """Two outgoing legs are not a transfer."""
    a, b = uuid4(), uuid4()
    assert (
        detect_transfers([_tx(account_id=a, amount=-50000), _tx(account_id=b, amount=-50000)]) == []
    )


def test_non_personal_and_rejected_are_excluded() -> None:
    """Confirmed roles are never re-suggested; a rejected leg never settled."""
    a, b, c = uuid4(), uuid4(), uuid4()
    out_confirmed = _tx(account_id=a, amount=-50000, role=TransactionRole.TRANSFER)
    inc = _tx(account_id=b, amount=50000)
    out_rejected = _tx(account_id=c, amount=-50000, status=TransactionStatus.REJECTED)

    assert detect_transfers([out_confirmed, inc, out_rejected]) == []


def test_greedy_one_to_one_prefers_the_closest_match() -> None:
    """A leg is used at most once; the smallest amount delta wins."""
    a, b, c = uuid4(), uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000)
    exact = _tx(account_id=b, amount=50000)  # delta 0
    feed = _tx(account_id=c, amount=49990)  # delta 10, would also qualify

    suggestions = detect_transfers([out, exact, feed])

    assert len(suggestions) == 1
    assert suggestions[0].incoming_transaction_id == exact.id


def test_half_transfer_yields_nothing() -> None:
    """An outgoing leg to an unconnected account has no counterpart."""
    assert detect_transfers([_tx(account_id=uuid4(), amount=-50000)]) == []


def test_missing_dates_are_skipped_without_error() -> None:
    """A transaction with neither booked_at nor value_date is not a candidate."""
    a, b = uuid4(), uuid4()
    undated = _tx(account_id=a, amount=-50000, booked_at=None, value_date=None)
    inc = _tx(account_id=b, amount=50000)

    assert detect_transfers([undated, inc]) == []


def test_value_date_is_used_when_booked_at_is_absent() -> None:
    """A pending leg dated only by value_date still pairs within the window."""
    a, b = uuid4(), uuid4()
    out = _tx(
        account_id=a,
        amount=-50000,
        booked_at=None,
        value_date=_BASE,
        status=TransactionStatus.PENDING,
    )
    inc = _tx(account_id=b, amount=50000, booked_at=_BASE)

    assert len(detect_transfers([out, inc])) == 1
