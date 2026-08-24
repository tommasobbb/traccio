"""Tests for the pure dashboard aggregation (``domain/dashboard``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

import pytest

from traccio.domain import (
    CategorySummary,
    CurrencySummary,
    DaySummary,
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
    booked_at: datetime | None = None,
    value_date: datetime | None = None,
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
        booked_at=booked_at,
        value_date=value_date,
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


def _assert_days_sum_to_total(summary: CurrencySummary) -> None:
    """Same invariant as ``_assert_partition_sums_to_total``, but ``by_day``
    only holds this when every member has a bucketable date — see the
    "excludes an undated member" test below for the one case it does not."""
    assert sum(e.spending.amount for e in summary.by_day) == summary.spending.amount
    assert sum(e.income.amount for e in summary.by_day) == summary.income.amount
    assert sum(e.transaction_count for e in summary.by_day) == summary.transaction_count


def test_day_partition_sums_to_the_currency_total_when_every_member_is_dated() -> None:
    members = [
        _tx(amount=-3000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-2000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-1500, booked_at=datetime(2026, 8, 11, tzinfo=UTC)),
        _tx(amount=5000, booked_at=datetime(2026, 8, 11, tzinfo=UTC)),
    ]
    summaries = summarize(members)
    _assert_days_sum_to_total(summaries[0])


def test_by_day_sorted_chronologically() -> None:
    members = [
        _tx(amount=-1000, booked_at=datetime(2026, 8, 15, tzinfo=UTC)),
        _tx(amount=-2000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-3000, booked_at=datetime(2026, 8, 12, tzinfo=UTC)),
    ]
    summaries = summarize(members)
    assert [e.day.isoformat() for e in summaries[0].by_day] == [
        "2026-08-10",
        "2026-08-12",
        "2026-08-15",
    ]


def test_by_day_falls_back_to_value_date_when_booked_at_is_unset() -> None:
    members = [
        _tx(amount=-1000, value_date=datetime(2026, 8, 20, tzinfo=UTC)),
    ]
    summaries = summarize(members)
    assert summaries[0].by_day == (
        DaySummary(
            day=datetime(2026, 8, 20, tzinfo=UTC).date(),
            spending=Money(amount=1000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )


def test_by_day_treats_a_naive_datetime_as_utc() -> None:
    """A value round-tripped through SQLite comes back naive; it must still
    bucket under the same UTC day, not raise or silently shift a day."""
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 20, 23, 30))]
    summaries = summarize(members)
    assert [e.day.isoformat() for e in summaries[0].by_day] == ["2026-08-20"]


def test_by_day_excludes_a_member_with_neither_date_but_keeps_it_in_the_total() -> None:
    """The one place ``by_day`` does not sum back to the parent total: an
    undated member has nowhere to bucket, but is still real spending."""
    members = [
        _tx(amount=-3000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-1000),  # no booked_at, no value_date
    ]
    summaries = summarize(members)
    assert summaries[0].spending == Money(amount=4000, currency="EUR")
    assert summaries[0].transaction_count == 2
    assert sum(e.transaction_count for e in summaries[0].by_day) == 1


def test_zero_effective_amount_member_counted_but_not_summed_in_its_day() -> None:
    """Same posture as the currency and category levels: a transfer leg still
    counts toward its day's transaction_count but neither magnitude."""
    day = datetime(2026, 8, 10, tzinfo=UTC)
    members = [
        _tx(amount=-5000, booked_at=day),
        _tx(amount=-3000, role=TransactionRole.TRANSFER, booked_at=day),
    ]
    summaries = summarize(members)
    entry = summaries[0].by_day[0]
    assert entry.spending == Money(amount=5000, currency="EUR")
    assert entry.income == Money(amount=0, currency="EUR")
    assert entry.transaction_count == 2


def test_same_day_in_two_currencies_stays_two_separate_entries() -> None:
    """No FX in Traccio: a day present in both currencies never gets summed
    into one combined figure."""
    day = datetime(2026, 8, 10, tzinfo=UTC)
    members = [
        _tx(amount=-5000, currency="EUR", booked_at=day),
        _tx(amount=-3000, currency="USD", booked_at=day),
    ]
    summaries = summarize(members)
    eur_summary, usd_summary = summaries
    assert eur_summary.by_day == (
        DaySummary(
            day=day.date(),
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )
    assert usd_summary.by_day == (
        DaySummary(
            day=day.date(),
            spending=Money(amount=3000, currency="USD"),
            income=Money(amount=0, currency="USD"),
            transaction_count=1,
        ),
    )


def test_advance_member_share_attributed_to_its_own_day() -> None:
    """The advance's declared share, not the full amount, lands in its day's
    spending — the same M2 'done when' as at the currency and category levels."""
    day = datetime(2026, 8, 10, tzinfo=UTC)
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE, booked_at=day)
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}
    summaries = summarize([advance_tx], advance_shares=shares)
    assert summaries[0].by_day == (
        DaySummary(
            day=day.date(),
            spending=Money(amount=20000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )
