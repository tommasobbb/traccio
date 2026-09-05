"""Tests for transfer detection (the pure matcher in ``services/transfers``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented references) — see ``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from traccio.domain import (
    AccountKind,
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
    TransferKind,
)
from traccio.services.transfers import (
    REASON_CURRENCY_MISMATCH,
    REASON_NOT_OPPOSITE_SIGNS,
    REASON_NOT_PERSONAL,
    REASON_NOT_TWO_OUTFLOWS,
    REASON_REJECTED,
    REASON_SAME_ACCOUNT,
    REASON_ZERO_AMOUNT,
    TransferPairError,
    detect_transfers,
    validate_transfer_pair,
)

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


def test_same_sign_does_not_match_without_account_kinds() -> None:
    """Two outflows are not a two-sided transfer, and without ``account_kinds``
    they are not a funded payment either."""
    a, b = uuid4(), uuid4()
    assert (
        detect_transfers([_tx(account_id=a, amount=-50000), _tx(account_id=b, amount=-50000)]) == []
    )


def test_detects_a_funded_payment_when_one_leg_is_a_wallet() -> None:
    """Two outflows, one on a wallet, same amount -> a funded-payment suggestion.

    The wallet leg is the real purchase (``incoming``); the bank leg funds it
    (``outgoing``, the leg that will be zeroed on confirm).
    """
    bank, wallet = uuid4(), uuid4()
    card_charge = _tx(account_id=bank, amount=-1290)
    wallet_payment = _tx(account_id=wallet, amount=-1290)

    [suggestion] = detect_transfers(
        [card_charge, wallet_payment],
        account_kinds={bank: AccountKind.CURRENT, wallet: AccountKind.WALLET},
    )

    assert suggestion.kind is TransferKind.FUNDED_PAYMENT
    assert suggestion.outgoing_transaction_id == card_charge.id
    assert suggestion.incoming_transaction_id == wallet_payment.id
    assert suggestion.outgoing_amount == -1290
    assert suggestion.incoming_amount == -1290


def test_no_funded_payment_when_neither_leg_is_a_wallet() -> None:
    """Two bank outflows: nothing tells detection which one funds the other."""
    a, b = uuid4(), uuid4()
    assert (
        detect_transfers(
            [_tx(account_id=a, amount=-1290), _tx(account_id=b, amount=-1290)],
            account_kinds={a: AccountKind.CURRENT, b: AccountKind.SAVINGS},
        )
        == []
    )


def test_no_funded_payment_when_both_legs_are_wallets() -> None:
    """Two wallet outflows are just as ambiguous — not suggested."""
    a, b = uuid4(), uuid4()
    assert (
        detect_transfers(
            [_tx(account_id=a, amount=-1290), _tx(account_id=b, amount=-1290)],
            account_kinds={a: AccountKind.WALLET, b: AccountKind.WALLET},
        )
        == []
    )


def test_funded_payment_uses_its_own_amount_tolerance() -> None:
    """The funding tolerance is separate from the two-sided one and 0 by default."""
    bank, wallet = uuid4(), uuid4()
    charge = _tx(account_id=bank, amount=-1290)
    payment = _tx(account_id=wallet, amount=-1250)  # 40 cents off
    kinds = {bank: AccountKind.CARD, wallet: AccountKind.WALLET}

    assert detect_transfers([charge, payment], account_kinds=kinds) == []
    assert (
        len(
            detect_transfers(
                [charge, payment],
                account_kinds=kinds,
                funding_amount_tolerance_cents=100,
            )
        )
        == 1
    )


def test_funded_payment_respects_the_day_window() -> None:
    """The shared ``window_days`` bounds funded-payment suggestions too."""
    bank, wallet = uuid4(), uuid4()
    charge = _tx(account_id=bank, amount=-1290, booked_at=_BASE)
    payment = _tx(account_id=wallet, amount=-1290, booked_at=_BASE + timedelta(days=6))
    kinds = {bank: AccountKind.CURRENT, wallet: AccountKind.WALLET}

    assert detect_transfers([charge, payment], account_kinds=kinds, window_days=4) == []
    assert len(detect_transfers([charge, payment], account_kinds=kinds, window_days=7)) == 1


def test_funded_payment_respects_dismissals() -> None:
    """A rejected funded-payment pair is not proposed again."""
    bank, wallet = uuid4(), uuid4()
    charge = _tx(account_id=bank, amount=-1290)
    payment = _tx(account_id=wallet, amount=-1290)

    assert (
        detect_transfers(
            [charge, payment],
            account_kinds={bank: AccountKind.CURRENT, wallet: AccountKind.WALLET},
            dismissed_pairs={frozenset({charge.id, payment.id})},
        )
        == []
    )


def test_two_sided_pair_is_ranked_ahead_of_a_funded_payment_on_a_tie() -> None:
    """When a wallet leg could pair either way, the opposite-sign match wins."""
    bank, wallet, other_bank = uuid4(), uuid4(), uuid4()
    wallet_payment = _tx(account_id=wallet, amount=-1290)
    card_charge = _tx(account_id=bank, amount=-1290)  # would be a funded payment
    real_credit = _tx(account_id=other_bank, amount=1290)  # a clean opposite leg
    kinds = {
        bank: AccountKind.CURRENT,
        wallet: AccountKind.WALLET,
        other_bank: AccountKind.CURRENT,
    }

    suggestions = detect_transfers([wallet_payment, card_charge, real_credit], account_kinds=kinds)

    # The wallet payment is consumed by the two-sided match; the card charge is
    # left with no partner.
    assert len(suggestions) == 1
    assert suggestions[0].kind is TransferKind.TWO_SIDED
    assert suggestions[0].incoming_transaction_id == real_credit.id


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


def test_dismissed_pair_is_not_suggested() -> None:
    """A rejected pair is filtered out even though it otherwise matches."""
    a, b = uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000)
    inc = _tx(account_id=b, amount=50000)
    dismissed = {frozenset({out.id, inc.id})}

    assert detect_transfers([out, inc]) != []
    assert detect_transfers([out, inc], dismissed_pairs=dismissed) == []


def test_dismissing_one_pair_leaves_another_match() -> None:
    """Only the dismissed pair is suppressed; a different valid pair still shows."""
    a, b, c, d = uuid4(), uuid4(), uuid4(), uuid4()
    out1 = _tx(account_id=a, amount=-50000)
    inc1 = _tx(account_id=b, amount=50000)
    out2 = _tx(account_id=c, amount=-30000)
    inc2 = _tx(account_id=d, amount=30000)
    dismissed = {frozenset({out1.id, inc1.id})}

    suggestions = detect_transfers([out1, inc1, out2, inc2], dismissed_pairs=dismissed)

    assert len(suggestions) == 1
    assert {suggestions[0].outgoing_transaction_id, suggestions[0].incoming_transaction_id} == {
        out2.id,
        inc2.id,
    }


def test_window_scan_still_pairs_after_an_out_of_window_candidate() -> None:
    """Sorting candidates by date and stopping the inner scan at the window
    edge must not hide a valid nearby pair that sits after a far-apart one."""
    a, b, c = uuid4(), uuid4(), uuid4()
    stale = _tx(account_id=a, amount=-50000, booked_at=_BASE)
    out = _tx(account_id=b, amount=-50000, booked_at=_BASE + timedelta(days=30))
    inc = _tx(account_id=c, amount=50000, booked_at=_BASE + timedelta(days=31))

    suggestions = detect_transfers([stale, out, inc])

    assert len(suggestions) == 1
    assert {suggestions[0].outgoing_transaction_id, suggestions[0].incoming_transaction_id} == {
        out.id,
        inc.id,
    }


def test_tie_break_is_deterministic_across_input_orders() -> None:
    """Two equally good partners for one leg (same amount delta, same day gap)
    resolve by transaction id, so the result never depends on input order."""
    a, b, c = uuid4(), uuid4(), uuid4()
    out = _tx(account_id=a, amount=-50000)
    inc1 = _tx(account_id=b, amount=50000)
    inc2 = _tx(account_id=c, amount=50000)

    forward = detect_transfers([out, inc1, inc2])
    backward = detect_transfers([out, inc2, inc1])

    assert len(forward) == len(backward) == 1
    assert forward[0].incoming_transaction_id == backward[0].incoming_transaction_id
    assert forward[0].incoming_transaction_id == min(inc1.id, inc2.id, key=str)


def test_validate_transfer_pair_accepts_a_clean_pair() -> None:
    """A structurally valid opposite-sign pair validates without raising."""
    out = _tx(account_id=uuid4(), amount=-50000)
    inc = _tx(account_id=uuid4(), amount=50000)

    validate_transfer_pair(out, inc)  # does not raise


def test_validate_transfer_pair_ignores_tolerance_and_window() -> None:
    """An explicit confirm may link a pair a detector would never suggest."""
    out = _tx(account_id=uuid4(), amount=-50000, booked_at=_BASE)
    # A large gap and a large amount delta: outside detection tolerance/window,
    # but the user is allowed to confirm it explicitly.
    inc = _tx(account_id=uuid4(), amount=10, booked_at=_BASE + timedelta(days=365))

    validate_transfer_pair(out, inc)  # does not raise
    assert detect_transfers([out, inc]) == []


def test_validate_transfer_pair_rejects_same_account() -> None:
    a = uuid4()
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(_tx(account_id=a, amount=-50000), _tx(account_id=a, amount=50000))
    assert exc.value.reason == REASON_SAME_ACCOUNT


def test_validate_transfer_pair_rejects_currency_mismatch() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=-50000, currency="EUR"),
            _tx(account_id=uuid4(), amount=50000, currency="USD"),
        )
    assert exc.value.reason == REASON_CURRENCY_MISMATCH


def test_validate_transfer_pair_rejects_same_sign() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=-50000), _tx(account_id=uuid4(), amount=-50000)
        )
    assert exc.value.reason == REASON_NOT_OPPOSITE_SIGNS


def test_validate_transfer_pair_rejects_non_personal_leg() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=-50000, role=TransactionRole.ADVANCE),
            _tx(account_id=uuid4(), amount=50000),
        )
    assert exc.value.reason == REASON_NOT_PERSONAL


def test_validate_transfer_pair_rejects_rejected_leg() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=-50000, status=TransactionStatus.REJECTED),
            _tx(account_id=uuid4(), amount=50000),
        )
    assert exc.value.reason == REASON_REJECTED


def test_validate_transfer_pair_rejects_zero_amount() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=0), _tx(account_id=uuid4(), amount=50000)
        )
    assert exc.value.reason == REASON_ZERO_AMOUNT


def test_validate_funded_payment_accepts_two_outflows() -> None:
    """For a funded payment both legs must be outflows; ``outgoing`` funds
    ``incoming``."""
    funding = _tx(account_id=uuid4(), amount=-1290)
    funded = _tx(account_id=uuid4(), amount=-1290)

    validate_transfer_pair(funding, funded, kind=TransferKind.FUNDED_PAYMENT)  # does not raise


def test_validate_funded_payment_rejects_an_opposite_sign_pair() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=-1290),
            _tx(account_id=uuid4(), amount=1290),
            kind=TransferKind.FUNDED_PAYMENT,
        )
    assert exc.value.reason == REASON_NOT_TWO_OUTFLOWS


def test_validate_funded_payment_rejects_two_inflows() -> None:
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=uuid4(), amount=1290),
            _tx(account_id=uuid4(), amount=1290),
            kind=TransferKind.FUNDED_PAYMENT,
        )
    assert exc.value.reason == REASON_NOT_TWO_OUTFLOWS


def test_validate_funded_payment_still_rejects_a_shared_account() -> None:
    """The structural checks are shared across kinds."""
    a = uuid4()
    with pytest.raises(TransferPairError) as exc:
        validate_transfer_pair(
            _tx(account_id=a, amount=-1290),
            _tx(account_id=a, amount=-1290),
            kind=TransferKind.FUNDED_PAYMENT,
        )
    assert exc.value.reason == REASON_SAME_ACCOUNT
