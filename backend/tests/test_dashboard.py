"""Tests for the pure dashboard aggregation (``domain/dashboard``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``.claude/rules/data-safety.md``.
"""

from datetime import UTC, date, datetime
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest

from traccio.domain import (
    AccountSummary,
    BucketGranularity,
    BucketSummary,
    CategoryGroupSummary,
    CategorySummary,
    CurrencySummary,
    KeyStrategy,
    Money,
    Transaction,
    TransactionRole,
    TransactionStatus,
    compare,
    split_meal_voucher_transactions,
    summarize,
    summarize_comparisons,
)

_ACCOUNT_A = UUID("11111111-1111-1111-1111-111111111111")
_ACCOUNT_B = UUID("22222222-2222-2222-2222-222222222222")


def _tx(
    *,
    amount: int = -5000,
    currency: str = "EUR",
    role: TransactionRole = TransactionRole.PERSONAL,
    status: TransactionStatus = TransactionStatus.BOOKED,
    confirmed_category_id: UUID | None = None,
    booked_at: datetime | None = None,
    value_date: datetime | None = None,
    account_id: UUID = _ACCOUNT_A,
) -> Transaction:
    """Build a synthetic transaction."""
    return Transaction(
        user_id=uuid4(),
        account_id=account_id,
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
            average_daily_spending=None,
            by_category=(
                CategoryGroupSummary(
                    category_id=None,
                    spending=Money(amount=5000, currency="EUR"),
                    income=Money(amount=2000, currency="EUR"),
                    transaction_count=2,
                    direct_spending=Money(amount=5000, currency="EUR"),
                    direct_income=Money(amount=2000, currency="EUR"),
                    direct_transaction_count=2,
                ),
            ),
            by_bucket=(),  # neither member has a booked_at/value_date
            by_account=(
                AccountSummary(
                    account_id=_ACCOUNT_A,
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
    assert summaries[0].spending == Money(amount=5000, currency="EUR")
    assert summaries[0].income == Money(amount=0, currency="EUR")
    assert summaries[0].transaction_count == 2


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
    assert summaries[0].spending == Money(amount=20000, currency="EUR")
    assert summaries[0].transaction_count == 1


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


# MARK: by_category (CategoryGroupSummary — roots with rolled-up children)


def _assert_group_invariant(group: CategoryGroupSummary) -> None:
    """The invariant `direct_*` exists for: a root's rollup always equals its
    own direct totals plus every child's, with no unexplained remainder."""
    assert group.spending.amount == group.direct_spending.amount + sum(
        c.spending.amount for c in group.children
    )
    assert group.income.amount == group.direct_income.amount + sum(
        c.income.amount for c in group.children
    )
    assert group.transaction_count == group.direct_transaction_count + sum(
        c.transaction_count for c in group.children
    )


def _assert_category_partition_sums_to_total(summary: CurrencySummary) -> None:
    assert sum(g.spending.amount for g in summary.by_category) == summary.spending.amount
    assert sum(g.income.amount for g in summary.by_category) == summary.income.amount
    assert sum(g.transaction_count for g in summary.by_category) == summary.transaction_count


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
    _assert_category_partition_sums_to_total(summaries[0])
    for group in summaries[0].by_category:
        _assert_group_invariant(group)


def test_uncategorized_transaction_falls_into_the_none_root_with_no_children() -> None:
    """A transaction with no effective category is a real, counted root bucket
    — never silently dropped, and never confused with an actual root's
    children."""
    members = [_tx(amount=-5000)]
    summaries = summarize(members)
    assert summaries[0].by_category == (
        CategoryGroupSummary(
            category_id=None,
            spending=Money(amount=5000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
            direct_spending=Money(amount=5000, currency="EUR"),
            direct_income=Money(amount=0, currency="EUR"),
            direct_transaction_count=1,
        ),
    )


def test_child_category_rolls_up_into_its_root_group() -> None:
    """A transaction confirmed on a child lands in the root's rollup and as
    one of the root's `children`, not as a top-level entry of its own."""
    root, child = uuid4(), uuid4()
    members = [
        _tx(amount=-3000, confirmed_category_id=root),
        _tx(amount=-2000, confirmed_category_id=child),
    ]
    summaries = summarize(members, parents={root: None, child: root})
    [group] = summaries[0].by_category
    assert group.category_id == root
    assert group.spending == Money(amount=5000, currency="EUR")
    assert group.direct_spending == Money(amount=3000, currency="EUR")
    assert group.direct_transaction_count == 1
    assert group.children == (
        CategorySummary(
            category_id=child,
            spending=Money(amount=2000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )
    _assert_group_invariant(group)


def test_root_with_only_children_has_zero_direct_totals() -> None:
    """A root never directly confirmed on, only via its children — `direct_*`
    is genuinely zero, not omitted or defaulted from missing data."""
    root, child_a, child_b = uuid4(), uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=child_a),
        _tx(amount=-2000, confirmed_category_id=child_b),
    ]
    summaries = summarize(members, parents={root: None, child_a: root, child_b: root})
    [group] = summaries[0].by_category
    assert group.direct_spending == Money(amount=0, currency="EUR")
    assert group.direct_transaction_count == 0
    assert group.spending == Money(amount=3000, currency="EUR")
    assert len(group.children) == 2
    _assert_group_invariant(group)


def test_a_category_missing_from_parents_degrades_to_its_own_root() -> None:
    """A category id present on a transaction but absent from `parents` (a
    rare delete race) is treated as its own root rather than raising."""
    orphan = uuid4()
    members = [_tx(amount=-1000, confirmed_category_id=orphan)]
    summaries = summarize(members, parents={})
    assert summaries[0].by_category == (
        CategoryGroupSummary(
            category_id=orphan,
            spending=Money(amount=1000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
            direct_spending=Money(amount=1000, currency="EUR"),
            direct_income=Money(amount=0, currency="EUR"),
            direct_transaction_count=1,
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
    [entry] = summaries[0].by_category
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
    assert eur_summary.by_category[0].spending == Money(amount=5000, currency="EUR")
    assert usd_summary.by_category[0].spending == Money(amount=3000, currency="USD")


def test_advance_member_share_attributed_to_its_own_category() -> None:
    """The advance's declared share, not the full amount, lands in its
    category's spending — the same M2 'done when' as at the currency level."""
    travel = uuid4()
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE, confirmed_category_id=travel)
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}
    summaries = summarize([advance_tx], advance_shares=shares)
    assert summaries[0].by_category[0].spending == Money(amount=20000, currency="EUR")


def test_by_category_sorted_by_spending_then_income_descending() -> None:
    biggest, middle, smallest = uuid4(), uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=smallest),
        _tx(amount=-3000, confirmed_category_id=biggest),
        _tx(amount=-2000, confirmed_category_id=middle),
    ]
    summaries = summarize(members)
    assert [g.category_id for g in summaries[0].by_category] == [biggest, middle, smallest]


def test_by_category_tiebreak_is_deterministic_and_none_sorts_first() -> None:
    """Equal spending across roots (including the None bucket) must not raise
    from comparing a UUID to None, and the order must be stable."""
    a, b = uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=a),
        _tx(amount=-1000, confirmed_category_id=b),
        _tx(amount=-1000),  # None bucket, same magnitude
    ]
    first_run = [g.category_id for g in summarize(members)[0].by_category]
    second_run = [g.category_id for g in summarize(members)[0].by_category]
    assert first_run == second_run
    assert first_run[0] is None  # "" sorts before any UUID's str()


def test_children_sorted_by_spending_then_income_descending() -> None:
    root = uuid4()
    biggest, smallest = uuid4(), uuid4()
    members = [
        _tx(amount=-1000, confirmed_category_id=smallest),
        _tx(amount=-3000, confirmed_category_id=biggest),
    ]
    summaries = summarize(members, parents={root: None, biggest: root, smallest: root})
    [group] = summaries[0].by_category
    assert [c.category_id for c in group.children] == [biggest, smallest]


# MARK: by_bucket (BucketSummary — gap-filled time buckets)


def _assert_bucket_partition_sums_to_total(summary: CurrencySummary) -> None:
    assert sum(b.spending.amount for b in summary.by_bucket) == summary.spending.amount
    assert sum(b.income.amount for b in summary.by_bucket) == summary.income.amount
    assert sum(b.transaction_count for b in summary.by_bucket) == summary.transaction_count


def test_day_partition_sums_to_the_currency_total_when_every_member_is_dated() -> None:
    members = [
        _tx(amount=-3000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-2000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-1500, booked_at=datetime(2026, 8, 11, tzinfo=UTC)),
        _tx(amount=5000, booked_at=datetime(2026, 8, 11, tzinfo=UTC)),
    ]
    summaries = summarize(members)
    _assert_bucket_partition_sums_to_total(summaries[0])


def test_by_bucket_sorted_chronologically_without_gap_fill() -> None:
    """No `period_start`/`period_end` given: only actual buckets, sorted."""
    members = [
        _tx(amount=-1000, booked_at=datetime(2026, 8, 15, tzinfo=UTC)),
        _tx(amount=-2000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-3000, booked_at=datetime(2026, 8, 12, tzinfo=UTC)),
    ]
    summaries = summarize(members)
    assert [b.start.isoformat() for b in summaries[0].by_bucket] == [
        "2026-08-10",
        "2026-08-12",
        "2026-08-15",
    ]


def test_day_bucket_end_is_exclusive_start_plus_one() -> None:
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 10, tzinfo=UTC))]
    summaries = summarize(members)
    [bucket] = summaries[0].by_bucket
    assert bucket.start == date(2026, 8, 10)
    assert bucket.end == date(2026, 8, 11)


def test_by_bucket_falls_back_to_value_date_when_booked_at_is_unset() -> None:
    members = [_tx(amount=-1000, value_date=datetime(2026, 8, 20, tzinfo=UTC))]
    summaries = summarize(members)
    assert summaries[0].by_bucket == (
        BucketSummary(
            start=date(2026, 8, 20),
            end=date(2026, 8, 21),
            spending=Money(amount=1000, currency="EUR"),
            income=Money(amount=0, currency="EUR"),
            transaction_count=1,
        ),
    )


def test_by_bucket_treats_a_naive_datetime_as_utc() -> None:
    """A value round-tripped through SQLite comes back naive; it must still
    bucket under the same UTC day, not raise or silently shift a day."""
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 20, 23, 30))]
    summaries = summarize(members)
    assert [b.start.isoformat() for b in summaries[0].by_bucket] == ["2026-08-20"]


def test_by_bucket_excludes_a_member_with_neither_date_but_keeps_it_in_the_total() -> None:
    """The one place `by_bucket` does not sum back to the parent total: an
    undated member has nowhere to bucket, but is still real spending."""
    members = [
        _tx(amount=-3000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-1000),  # no booked_at, no value_date
    ]
    summaries = summarize(members)
    assert summaries[0].spending == Money(amount=4000, currency="EUR")
    assert summaries[0].transaction_count == 2
    assert sum(b.transaction_count for b in summaries[0].by_bucket) == 1


def test_zero_effective_amount_member_counted_but_not_summed_in_its_bucket() -> None:
    day = datetime(2026, 8, 10, tzinfo=UTC)
    members = [
        _tx(amount=-5000, booked_at=day),
        _tx(amount=-3000, role=TransactionRole.TRANSFER, booked_at=day),
    ]
    summaries = summarize(members)
    [entry] = summaries[0].by_bucket
    assert entry.spending == Money(amount=5000, currency="EUR")
    assert entry.income == Money(amount=0, currency="EUR")
    assert entry.transaction_count == 2


def test_same_bucket_in_two_currencies_stays_two_separate_entries() -> None:
    day = datetime(2026, 8, 10, tzinfo=UTC)
    members = [
        _tx(amount=-5000, currency="EUR", booked_at=day),
        _tx(amount=-3000, currency="USD", booked_at=day),
    ]
    summaries = summarize(members)
    eur_summary, usd_summary = summaries
    assert eur_summary.by_bucket[0].spending == Money(amount=5000, currency="EUR")
    assert usd_summary.by_bucket[0].spending == Money(amount=3000, currency="USD")


def test_advance_member_share_attributed_to_its_own_bucket() -> None:
    day = datetime(2026, 8, 10, tzinfo=UTC)
    advance_tx = _tx(amount=-100000, role=TransactionRole.ADVANCE, booked_at=day)
    shares = {advance_tx.id: Money(amount=-20000, currency="EUR")}
    summaries = summarize([advance_tx], advance_shares=shares)
    assert summaries[0].by_bucket[0].spending == Money(amount=20000, currency="EUR")


def test_week_granularity_buckets_start_on_monday() -> None:
    # 2026-08-13 is a Thursday; its ISO week starts Monday 2026-08-10.
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 13, tzinfo=UTC))]
    summaries = summarize(members, granularity=BucketGranularity.WEEK)
    [bucket] = summaries[0].by_bucket
    assert bucket.start == date(2026, 8, 10)
    assert bucket.end == date(2026, 8, 17)


def test_month_granularity_buckets_by_first_of_month() -> None:
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 27, tzinfo=UTC))]
    summaries = summarize(members, granularity=BucketGranularity.MONTH)
    [bucket] = summaries[0].by_bucket
    assert bucket.start == date(2026, 8, 1)
    assert bucket.end == date(2026, 9, 1)


def test_month_granularity_crosses_a_year_boundary() -> None:
    members = [_tx(amount=-1000, booked_at=datetime(2026, 12, 15, tzinfo=UTC))]
    summaries = summarize(members, granularity=BucketGranularity.MONTH)
    [bucket] = summaries[0].by_bucket
    assert bucket.start == date(2026, 12, 1)
    assert bucket.end == date(2027, 1, 1)


def test_gap_fill_produces_a_zero_bucket_for_a_day_with_no_transactions() -> None:
    members = [
        _tx(amount=-1000, booked_at=datetime(2026, 8, 10, tzinfo=UTC)),
        _tx(amount=-2000, booked_at=datetime(2026, 8, 12, tzinfo=UTC)),
    ]
    summaries = summarize(
        members,
        period_start=datetime(2026, 8, 10, tzinfo=UTC),
        period_end=datetime(2026, 8, 13, tzinfo=UTC),
    )
    assert [b.start.isoformat() for b in summaries[0].by_bucket] == [
        "2026-08-10",
        "2026-08-11",
        "2026-08-12",
    ]
    middle = summaries[0].by_bucket[1]
    assert middle.spending == Money(amount=0, currency="EUR")
    assert middle.transaction_count == 0


def test_gap_fill_covers_the_whole_period_even_with_no_transactions_at_all() -> None:
    summaries = summarize(
        [],
        period_start=datetime(2026, 8, 1, tzinfo=UTC),
        period_end=datetime(2026, 8, 4, tzinfo=UTC),
    )
    # No transactions means no currency at all — nothing to gap-fill for,
    # same as the empty-input case. Gap-fill only ever applies to a currency
    # that actually appears, since a bucket belongs to one currency.
    assert summaries == []


def test_open_period_falls_back_to_only_actual_buckets_no_gap_fill() -> None:
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 10, tzinfo=UTC))]
    summaries = summarize(members, period_start=datetime(2026, 8, 1, tzinfo=UTC), period_end=None)
    assert len(summaries[0].by_bucket) == 1


def test_a_transaction_near_midnight_utc_buckets_by_the_local_day_in_rome() -> None:
    """Europe/Rome is UTC+2 in August — 2026-08-09T23:30Z is 2026-08-10T01:30
    locally, so it must bucket under the *local* day 2026-08-10, not the UTC
    day 2026-08-09."""
    rome = ZoneInfo("Europe/Rome")
    members = [_tx(amount=-1000, booked_at=datetime(2026, 8, 9, 23, 30, tzinfo=UTC))]
    summaries = summarize(
        members,
        tz=rome,
        period_start=datetime(2026, 8, 9, 22, 0, tzinfo=UTC),  # 2026-08-10T00:00 Rome
        period_end=datetime(2026, 8, 10, 22, 0, tzinfo=UTC),  # 2026-08-11T00:00 Rome
    )
    assert [b.start.isoformat() for b in summaries[0].by_bucket] == ["2026-08-10"]
    assert summaries[0].by_bucket[0].spending == Money(amount=1000, currency="EUR")


# MARK: by_account


def _assert_account_partition_sums_to_total(summary: CurrencySummary) -> None:
    assert sum(a.spending.amount for a in summary.by_account) == summary.spending.amount
    assert sum(a.income.amount for a in summary.by_account) == summary.income.amount
    assert sum(a.transaction_count for a in summary.by_account) == summary.transaction_count


def test_account_partition_sums_to_the_currency_total() -> None:
    members = [
        _tx(amount=-3000, account_id=_ACCOUNT_A),
        _tx(amount=-2000, account_id=_ACCOUNT_B),
        _tx(amount=1000, account_id=_ACCOUNT_A),
    ]
    summaries = summarize(members)
    _assert_account_partition_sums_to_total(summaries[0])


def test_by_account_sorted_by_spending_then_income_descending() -> None:
    members = [
        _tx(amount=-1000, account_id=_ACCOUNT_B),
        _tx(amount=-3000, account_id=_ACCOUNT_A),
    ]
    summaries = summarize(members)
    assert [a.account_id for a in summaries[0].by_account] == [_ACCOUNT_A, _ACCOUNT_B]


def test_same_account_in_two_currencies_stays_two_separate_entries() -> None:
    members = [
        _tx(amount=-5000, currency="EUR", account_id=_ACCOUNT_A),
        _tx(amount=-3000, currency="USD", account_id=_ACCOUNT_A),
    ]
    summaries = summarize(members)
    eur_summary, usd_summary = summaries
    assert eur_summary.by_account[0].spending == Money(amount=5000, currency="EUR")
    assert usd_summary.by_account[0].spending == Money(amount=3000, currency="USD")


# MARK: average_daily_spending


def test_average_daily_spending_is_none_without_a_period_start() -> None:
    members = [_tx(amount=-3000)]
    summaries = summarize(members)
    assert summaries[0].average_daily_spending is None


def test_average_daily_spending_uses_the_nominal_period_when_now_is_omitted() -> None:
    """A closed period (`period_end` given) with no `now` assumes it already
    fully elapsed — €30 over three nominal days is €10/day."""
    members = [_tx(amount=-3000)]
    summaries = summarize(
        members,
        period_start=datetime(2026, 8, 1, tzinfo=UTC),
        period_end=datetime(2026, 8, 4, tzinfo=UTC),
    )
    assert summaries[0].average_daily_spending == Money(amount=1000, currency="EUR")


def test_average_daily_spending_uses_elapsed_days_not_nominal_for_an_open_period() -> None:
    """A month still in progress divides by days actually gone by, so a
    figure is not diluted by days that have not happened yet."""
    members = [_tx(amount=-3000)]
    summaries = summarize(
        members,
        period_start=datetime(2026, 8, 1, tzinfo=UTC),
        period_end=None,
        now=datetime(2026, 8, 4, tzinfo=UTC),
    )
    assert summaries[0].average_daily_spending == Money(amount=1000, currency="EUR")


def test_average_daily_spending_clamps_to_now_when_before_the_nominal_end() -> None:
    """`now` inside a closed period (the period is still ongoing) uses the
    elapsed span, not the full nominal length."""
    members = [_tx(amount=-3000)]
    summaries = summarize(
        members,
        period_start=datetime(2026, 8, 1, tzinfo=UTC),
        period_end=datetime(2026, 9, 1, tzinfo=UTC),
        now=datetime(2026, 8, 4, tzinfo=UTC),
    )
    assert summaries[0].average_daily_spending == Money(amount=1000, currency="EUR")


def test_average_daily_spending_is_none_for_an_open_period_with_no_now() -> None:
    members = [_tx(amount=-3000)]
    summaries = summarize(members, period_start=datetime(2026, 8, 1, tzinfo=UTC), period_end=None)
    assert summaries[0].average_daily_spending is None


def test_average_daily_spending_floors_to_at_least_one_elapsed_day() -> None:
    """`period_start == now` (day one) must not divide by zero."""
    members = [_tx(amount=-3000)]
    summaries = summarize(
        members,
        period_start=datetime(2026, 8, 1, tzinfo=UTC),
        period_end=None,
        now=datetime(2026, 8, 1, tzinfo=UTC),
    )
    assert summaries[0].average_daily_spending == Money(amount=3000, currency="EUR")


# MARK: compare / summarize_comparisons


def test_compare_reports_the_previous_periods_own_totals() -> None:
    current = summarize([_tx(amount=-5000)])[0]
    previous = summarize([_tx(amount=-3000), _tx(amount=1000)])[0]
    comparison = compare(current=current, previous=previous)
    assert comparison.spending == Money(amount=3000, currency="EUR")
    assert comparison.income == Money(amount=1000, currency="EUR")
    assert comparison.net == Money(amount=-2000, currency="EUR")


def test_compare_spending_delta_is_signed() -> None:
    current = summarize([_tx(amount=-5000)])[0]
    previous = summarize([_tx(amount=-3000)])[0]
    comparison = compare(current=current, previous=previous)
    assert comparison.spending_delta == Money(amount=2000, currency="EUR")

    decreased = compare(current=previous, previous=current)
    assert decreased.spending_delta == Money(amount=-2000, currency="EUR")


def test_compare_spending_delta_pct_is_none_on_a_zero_base() -> None:
    """Never `inf` — an explicit absence when the comparison period spent
    nothing at all."""
    current = summarize([_tx(amount=-5000)])[0]
    previous = summarize([_tx(amount=1000)])[0]  # income only, zero spending
    comparison = compare(current=current, previous=previous)
    assert comparison.spending_delta_pct is None


def test_compare_spending_delta_pct_is_a_ratio_not_a_percentage() -> None:
    current = summarize([_tx(amount=-6000)])[0]
    previous = summarize([_tx(amount=-3000)])[0]
    comparison = compare(current=current, previous=previous)
    assert comparison.spending_delta_pct == pytest.approx(1.0)


def test_summarize_comparisons_matches_by_currency() -> None:
    current = summarize([_tx(amount=-5000, currency="EUR"), _tx(amount=-1000, currency="USD")])
    previous = summarize([_tx(amount=-3000, currency="EUR"), _tx(amount=-500, currency="USD")])
    comparisons = summarize_comparisons(current, previous)
    assert set(comparisons) == {"EUR", "USD"}
    assert comparisons["EUR"].spending == Money(amount=3000, currency="EUR")
    assert comparisons["USD"].spending == Money(amount=500, currency="USD")


def test_summarize_comparisons_uses_a_zero_baseline_for_a_currency_absent_from_previous() -> None:
    """A currency spent in the current period but not at all in the
    comparison period still gets a comparison, against zero."""
    current = summarize([_tx(amount=-5000, currency="CHF")])
    previous: list[CurrencySummary] = []
    comparisons = summarize_comparisons(current, previous)
    assert comparisons["CHF"].spending == Money(amount=0, currency="CHF")
    assert comparisons["CHF"].spending_delta == Money(amount=5000, currency="CHF")
    assert comparisons["CHF"].spending_delta_pct is None


# --- split_meal_voucher_transactions (ADR 0029) -----------------------------


def test_split_meal_vouchers_with_empty_account_set_keeps_everything_in_main() -> None:
    """The setting-off case: an empty ``voucher_account_ids`` is a no-op split."""
    txns = [_tx(account_id=_ACCOUNT_A), _tx(account_id=_ACCOUNT_B)]
    main, vouchers = split_meal_voucher_transactions(txns, voucher_account_ids=set())
    assert main == txns
    assert vouchers == []


def test_split_meal_vouchers_separates_by_account_id() -> None:
    on_a = _tx(account_id=_ACCOUNT_A)
    on_b = _tx(account_id=_ACCOUNT_B)
    main, vouchers = split_meal_voucher_transactions(
        [on_a, on_b], voucher_account_ids={_ACCOUNT_B}
    )
    assert main == [on_a]
    assert vouchers == [on_b]


def test_split_meal_vouchers_preserves_order_within_each_half() -> None:
    first = _tx(account_id=_ACCOUNT_A)
    second = _tx(account_id=_ACCOUNT_B)
    third = _tx(account_id=_ACCOUNT_A)
    fourth = _tx(account_id=_ACCOUNT_B)
    main, vouchers = split_meal_voucher_transactions(
        [first, second, third, fourth], voucher_account_ids={_ACCOUNT_B}
    )
    assert main == [first, third]
    assert vouchers == [second, fourth]
