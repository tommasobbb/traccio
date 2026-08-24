"""Tests for the pure dashboard aggregation (``domain/dashboard``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from uuid import UUID, uuid4

import pytest

from traccio.domain import (
    CategorySummary,
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
    confirmed_category_id: UUID | None = None,
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
        confirmed_category_id=confirmed_category_id,
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
            by_category=(
                CategorySummary(
                    category_id=None,
                    spending=Money(amount=5000, currency="EUR"),
                    income=Money(amount=2000, currency="EUR"),
                    transaction_count=2,
                ),
            ),
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
            by_category=(
                CategorySummary(
                    category_id=None,
                    spending=Money(amount=5000, currency="EUR"),
                    income=Money(amount=0, currency="EUR"),
                    transaction_count=2,
                ),
            ),
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
            by_category=(
                CategorySummary(
                    category_id=None,
                    spending=Money(amount=20000, currency="EUR"),
                    income=Money(amount=0, currency="EUR"),
                    transaction_count=1,
                ),
            ),
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


def _assert_partition_sums_to_total(summary: CurrencySummary) -> None:
    """The invariant this whole feature exists to satisfy: a currency's
    category partition always sums back to that currency's own totals."""
    assert sum(e.spending.amount for e in summary.by_category) == summary.spending.amount
    assert sum(e.income.amount for e in summary.by_category) == summary.income.amount
    assert sum(e.transaction_count for e in summary.by_category) == summary.transaction_count


def test_category_partition_sums_to_the_currency_total() -> None:
    groceries, dining = uuid4(), uuid4()
    members = [
        _tx(amount=-3000, confirmed_category_id=groceries),
        _tx(amount=-2000, confirmed_category_id=groceries),
        _tx(amount=-1500, confirmed_category_id=dining),
        _tx(amount=5000),  # income, no category
        _tx(amount=-4000),  # spending, no category
    ]
    summaries = summarize(members)
    _assert_partition_sums_to_total(summaries[0])


def test_uncategorized_transaction_falls_into_the_none_bucket() -> None:
    """A transaction with no effective category is a real, counted bucket —
    never silently dropped from the partition."""
    members = [_tx(amount=-5000)]
    summaries = summarize(members)
    assert summaries[0].by_category == (
        CategorySummary(
            category_id=None,
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )


def test_zero_effective_amount_member_counted_but_not_summed_in_its_category() -> None:
    """A transfer leg still counts toward its category's transaction_count,
    same as at the currency level, but contributes to neither magnitude."""
    category_id = uuid4()
    members = [
        _tx(amount=-5000, confirmed_category_id=category_id),
        _tx(amount=-3000, role=TransactionRole.TRANSFER, confirmed_category_id=category_id),
    ]
    summaries = summarize(members)
    entry = summaries[0].by_category[0]
    assert entry.category_id == category_id
    assert entry.spending == Money(amount=5000, currency="EUR")
    assert entry.income == Money(amount=0, currency="EUR")
    assert entry.transaction_count == 2


def test_same_category_in_two_currencies_stays_two_separate_entries() -> None:
    """No FX in Traccio: a category present in both currencies never gets
    summed into one combined figure."""
    category_id = uuid4()
    members = [
        _tx(amount=-5000, currency="EUR", confirmed_category_id=category_id),
        _tx(amount=-3000, currency="USD", confirmed_category_id=category_id),
    ]
    summaries = summarize(members)
    eur_summary, usd_summary = summaries
    assert eur_summary.currency == "EUR"
    assert eur_summary.by_category == (
        CategorySummary(
            category_id=category_id,
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )
    assert usd_summary.currency == "USD"
    assert usd_summary.by_category == (
        CategorySummary(
            category_id=category_id,
            spending=Money(amount=3000, currency="USD"),
            income=Money(amount=0, currency="USD"),
            transaction_count=1,
        ),
    )


def test_advance_member_share_attributed_to_its_own_category() -> None:
    """The advance's declared share, not the full amount, lands in its
    category's spending — the same M2 'done when' as at the currency level."""
    travel = uuid4()
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE, confirmed_category_id=travel)
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}
    summaries = summarize([advance_tx], advance_shares=shares)
    assert summaries[0].by_category == (
        CategorySummary(
            category_id=travel,
            spending=Money(amount=20000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )


def test_by_category_sorted_by_spending_then_income_descending() -> None:
    biggest, middle, smallest = uuid4(), uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=smallest),
        _tx(amount=-3000, confirmed_category_id=biggest),
        _tx(amount=-2000, confirmed_category_id=middle),
    ]
    summaries = summarize(members)
    assert [e.category_id for e in summaries[0].by_category] == [biggest, middle, smallest]


def test_by_category_tiebreak_is_deterministic_and_none_sorts_by_empty_string() -> None:
    """Equal spending across categories (including the None bucket) must not
    raise from comparing a UUID to None, and the order must be stable."""
    a, b = uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=a),
        _tx(amount=-1000, confirmed_category_id=b),
        _tx(amount=-1000),  # None bucket, same magnitude
    ]
    first_run = [e.category_id for e in summarize(members)[0].by_category]
    second_run = [e.category_id for e in summarize(members)[0].by_category]
    assert first_run == second_run
    assert None in first_run
    assert first_run[0] is None  # "" sorts before any UUID's str()
