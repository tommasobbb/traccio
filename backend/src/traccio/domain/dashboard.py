"""The dashboard summary: real spending and income, per currency, over time.

M2's "done when" (``tasks/ROADMAP.md``): "I can tag a real advance from a real
trip and watch the dashboard show my actual share rather than the full
amount." This is the single place that answers "how much did I actually spend
and receive" from :func:`~traccio.domain.effective_amount.effective_amount`
alone — never raw ``amount`` (see ``docs/architecture.md``'s invariant that the
two are never mixed) — so a transfer between the user's own accounts does not
inflate spending, an advance counts only the user's declared share, and a
reimbursement is not income.

Each currency's totals additionally partition three ways (``docs/decisions/
0007-dashboard-aggregation.md``, third revision): by
:func:`~traccio.domain.categories.effective_category`, rolled up to each
category's root (``by_category``); by time bucket, gap-filled across the
requested period when both bounds are known (``by_bucket``); and by account
(``by_account``). A separate period's totals can be attached as ``comparison``
via :func:`compare`/:func:`summarize_comparisons` — a second, independent call
to :func:`summarize`, not a parameter of the first.

:func:`split_meal_voucher_transactions` (ADR 0029) is a *scoping* filter, the
same class of thing as the tracking-start floor (ADR 0024): it removes rows
before ``summarize`` ever sees them, rather than adding a second derivation
alongside ``effective_amount``. The router runs ``summarize`` twice — once on
the remaining transactions for the headline totals, once on the voucher
transactions for the "Buoni pasto" breakout — so both come from the one
aggregation function with no separate code path.

This module imports nothing outside ``domain/``.
"""

from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime, time, timedelta, tzinfo
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.categories import effective_category
from traccio.domain.effective_amount import effective_amount
from traccio.domain.enums import BucketGranularity
from traccio.domain.models import Transaction
from traccio.domain.money import CurrencyCode, Money
from traccio.domain.transaction_time import transaction_when
from traccio.domain.utc import as_aware_utc


def split_meal_voucher_transactions(
    transactions: Sequence[Transaction], *, voucher_account_ids: set[UUID]
) -> tuple[list[Transaction], list[Transaction]]:
    """Partition ``transactions`` into (everything else, meal-voucher spend).

    A meal-voucher transaction is one whose ``account_id`` is a
    voucher-kind account (ADR 0029) — the caller resolves that set from
    ``AccountKind.VOUCHER`` accounts before calling this, since ``domain/``
    has no account lookup of its own. Order is preserved within each half.
    Pure and total: with an empty ``voucher_account_ids`` (the setting is
    off, or the user has no voucher account), every transaction lands in the
    first list and the second is empty.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The transactions to partition.
    voucher_account_ids : set[UUID]
        Ids of the user's voucher-kind accounts.

    Returns
    -------
    tuple[list[Transaction], list[Transaction]]
        ``(main, vouchers)`` — ``main`` excludes every voucher transaction,
        ``vouchers`` holds only them.
    """
    main: list[Transaction] = []
    vouchers: list[Transaction] = []
    for transaction in transactions:
        if transaction.account_id in voucher_account_ids:
            vouchers.append(transaction)
        else:
            main.append(transaction)
    return main, vouchers


def _bucket_of(
    transaction: Transaction, *, granularity: BucketGranularity, tz: tzinfo
) -> date | None:
    """The local bucket start a transaction falls into, or ``None``.

    Same "when" as :func:`~traccio.db.repositories.list_transactions_in_period`
    uses to filter (:func:`~traccio.domain.transaction_time.transaction_when`,
    mirroring that query's SQL ``coalesce``) — so a row can never be counted
    in the period but excluded from every bucket, or vice versa.
    Every timestamp in this system is UTC (root ``docs/engineering.md``), but a value
    round-tripped through SQLite comes back naive; a naive value is treated as
    UTC rather than the local zone, per
    :func:`~traccio.domain.utc.as_aware_utc`. Bucketing itself
    happens in ``tz`` (not UTC) — at ``MONTH`` granularity a UTC bucketing
    would visibly misplace a day at either edge of a local month. ``None``
    when both dates are unset — there is nothing to bucket.
    """
    when = transaction_when(transaction)
    if when is None:
        return None
    aware = as_aware_utc(when)
    local_day = aware.astimezone(tz).date()
    return _bucket_start(local_day, granularity)


def _bucket_start(day: date, granularity: BucketGranularity) -> date:
    """The start of the bucket containing ``day``, at ``granularity``.

    ``WEEK`` starts on Monday (ISO), never Sunday. ``MONTH`` starts on the
    1st. Pure date arithmetic — no timezone involved once ``day`` is already a
    local calendar date.
    """
    if granularity is BucketGranularity.DAY:
        return day
    if granularity is BucketGranularity.WEEK:
        return day - timedelta(days=day.weekday())
    return day.replace(day=1)


def _bucket_end(start: date, granularity: BucketGranularity) -> date:
    """The exclusive end of the bucket that starts at ``start``.

    ``start`` must already be a bucket start (see :func:`_bucket_start`) — this
    does not re-align an arbitrary date.
    """
    if granularity is BucketGranularity.DAY:
        return start + timedelta(days=1)
    if granularity is BucketGranularity.WEEK:
        return start + timedelta(days=7)
    if start.month == 12:
        return date(start.year + 1, 1, 1)
    return date(start.year, start.month + 1, 1)


def _bucket_grid(
    *,
    period_start: datetime | None,
    period_end: datetime | None,
    granularity: BucketGranularity,
    tz: tzinfo,
) -> list[date] | None:
    """Every bucket start that overlaps ``[period_start, period_end)``, in ``tz``.

    ``None`` when either bound is missing — an open-ended period has no fixed
    grid to fill, so :func:`summarize` falls back to only the buckets that
    actually contain a transaction, same as before gap-fill existed. When both
    bounds are present, this is the **complete** series requested — including
    buckets with zero transactions — which is the whole point of moving
    gap-fill to the backend (``docs/decisions/0007-dashboard-aggregation.md``):
    the client no longer walks a calendar to invent empty bars.

    A bucket is included whenever any instant of it falls before
    ``period_end`` (localized) — i.e. its start, as a ``tz``-aware midnight,
    is strictly less than ``period_end`` localized to ``tz``. This mirrors the
    half-open ``[start, end)`` convention the transaction query itself uses.
    """
    if period_start is None or period_end is None:
        return None
    local_start = period_start.astimezone(tz)
    local_end = period_end.astimezone(tz)

    starts: list[date] = []
    current = _bucket_start(local_start.date(), granularity)
    while datetime.combine(current, time.min, tzinfo=tz) < local_end:
        starts.append(current)
        current = _bucket_end(current, granularity)
    return starts


def _average_daily_spending(
    spending: Money,
    *,
    period_start: datetime | None,
    period_end: datetime | None,
    now: datetime | None,
) -> Money | None:
    """Spending per elapsed day, or ``None`` when it cannot be derived.

    ``None`` whenever ``period_start`` is missing (nothing to divide the
    elapsed span from) or the period is open-ended (``period_end`` is
    ``None``) with no ``now`` supplied to bound it. ``now`` is an explicit
    parameter, never read from the clock in here, so this stays a pure,
    injectable function (mirrors the client's own
    ``TransactionPeriodPreset.range(calendar:now:)``) — the caller
    (``api/routers/dashboard.py``) passes ``datetime.now(UTC)``.

    Uses **elapsed** days, not the period's nominal length: a month still in
    progress divides by the days actually gone by, not the whole month, so a
    figure like "€42/day" is not diluted by days that have not happened yet.
    """
    if period_start is None:
        return None
    if period_end is None:
        if now is None:
            return None
        effective_end = now
    else:
        effective_end = min(now, period_end) if now is not None else period_end
    elapsed = (effective_end.date() - period_start.date()).days
    elapsed_days = max(1, elapsed)
    return Money(amount=spending.amount // elapsed_days, currency=spending.currency)


class CategorySummary(BaseModel):
    """Spending and income totals for one **child** category.

    Always nested inside a :class:`CategoryGroupSummary` as one of its
    ``children`` — a child category is never a top-level entry in
    ``by_category``, since ADR 0018's two-level hierarchy means every child
    has a root to roll up into.

    Attributes
    ----------
    category_id : UUID
        The child category's id — always set; a child is never the
        "no category" bucket (that lives at the root level, see
        :class:`CategoryGroupSummary`).
    spending : Money
        Total of every negative ``effective_amount`` confirmed/suggested
        directly on this child, negated to a positive magnitude.
    income : Money
        Total of every positive ``effective_amount`` directly on this child, a
        positive magnitude.
    transaction_count : int
        How many transactions carry this child as their
        :func:`~traccio.domain.categories.effective_category`.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    category_id: UUID
    spending: Money
    income: Money
    transaction_count: int


class CategoryGroupSummary(BaseModel):
    """Spending and income totals for one category **root**, its children rolled in.

    The root type of ``by_category`` (ADR 0018's two-level hierarchy landing
    in the dashboard). ``spending``/``income``/``transaction_count`` are a
    **rollup**: this root's own totals plus every child's. ``direct_*`` are
    the root's *own* transactions only — those confirmed/suggested on the root
    category itself, never on one of its children. Both are needed together:
    without ``direct_*``, expanding a root's children in the client would sum
    to *less* than the parent row, with an unexplained remainder.

    Invariant: ``spending == direct_spending + sum(c.spending for c in
    children)``, and the same for ``income``/``transaction_count`` — enforced
    by construction in :func:`summarize`, not asserted here.

    Attributes
    ----------
    category_id : UUID or None
        The root category's id, or ``None`` for the "no category" bucket — a
        real, counted entry with no children, never omitted.
    spending : Money
        This root's total spending, including every child's.
    income : Money
        This root's total income, including every child's.
    transaction_count : int
        This root's total transaction count, including every child's.
    direct_spending : Money
        Spending from transactions confirmed/suggested on the root itself,
        excluding any child.
    direct_income : Money
        Income from transactions confirmed/suggested on the root itself,
        excluding any child.
    direct_transaction_count : int
        Transaction count confirmed/suggested on the root itself, excluding
        any child.
    children : tuple[CategorySummary, ...]
        This root's children that have at least one transaction, sorted by
        ``spending`` descending, then ``income`` descending, then
        ``category_id`` for a deterministic order. A child with zero
        transactions is simply absent, same as an absent category anywhere
        else in this module.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    category_id: UUID | None
    spending: Money
    income: Money
    transaction_count: int
    direct_spending: Money
    direct_income: Money
    direct_transaction_count: int
    children: tuple[CategorySummary, ...] = ()


class BucketSummary(BaseModel):
    """Spending and income totals for one time bucket, within one currency.

    Attributes
    ----------
    start : date
        The bucket's start, a local calendar date (the request's ``tz``).
    end : date
        The bucket's exclusive end — for a ``DAY`` bucket, ``start + 1``. Sent
        explicitly rather than left for the client to derive, since computing
        "the last day of this ISO week/calendar month" client-side would be a
        derivation the client must not perform (``docs/engineering.md``), and
        could silently disagree with how this module actually bucketed.
    spending : Money
        Total spending in this bucket, a positive magnitude.
    income : Money
        Total income in this bucket, a positive magnitude.
    transaction_count : int
        How many transactions fall in this bucket.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    start: date
    end: date
    spending: Money
    income: Money
    transaction_count: int


class AccountSummary(BaseModel):
    """Spending and income totals for one account, within one currency.

    Attributes
    ----------
    account_id : UUID
        The account these totals belong to.
    spending : Money
        Total spending on this account, a positive magnitude.
    income : Money
        Total income on this account, a positive magnitude.
    transaction_count : int
        How many transactions fall on this account.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    account_id: UUID
    spending: Money
    income: Money
    transaction_count: int


class ComparisonSummary(BaseModel):
    """A comparison period's own totals, plus how the current period changed from it.

    Produced by :func:`compare`, never by :func:`summarize` itself — the
    comparison period is a second, independent aggregation the caller
    provides (``docs/decisions/0007-dashboard-aggregation.md``'s "the client
    sends *which* period to compare, not a boolean").

    Attributes
    ----------
    spending : Money
        The comparison period's own total spending, a positive magnitude.
    income : Money
        The comparison period's own total income, a positive magnitude.
    net : Money
        The comparison period's own net (``income - spending``), signed.
    spending_delta : Money
        The current period's spending minus this comparison period's, signed
        — positive means the current period spent more.
    spending_delta_pct : float or None
        ``spending_delta`` as a fraction of the comparison period's spending,
        or ``None`` when that spending was zero (division is undefined here,
        never ``inf``). The one float in this module: it is a ratio, not
        money, so the integer-cents rule does not apply to it.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    spending: Money
    income: Money
    net: Money
    spending_delta: Money
    spending_delta_pct: float | None


class CurrencySummary(BaseModel):
    """Spending and income totals for one currency over a period.

    ``spending`` and ``income`` are **positive magnitudes** — the same
    convention as :mod:`traccio.domain.advances` (``receivable``,
    ``outstanding``) — so they read naturally on a dashboard; ``net`` is the
    single **signed** figure, ``income - spending``.

    Attributes
    ----------
    currency : str
        ISO 4217 code this summary is expressed in. A period spanning multiple
        currencies produces one :class:`CurrencySummary` per currency;
        combining them into one base currency is the opt-in, additive
        ``converted`` view built outside this module (ADR 0021,
        ``api/routers/dashboard.py``), never by :func:`summarize` itself.
    spending : Money
        Total of every negative ``effective_amount``, negated to a positive
        magnitude. A zero ``effective_amount`` (a transfer, a reimbursement, a
        rejected movement) contributes to neither ``spending`` nor ``income``.
    income : Money
        Total of every positive ``effective_amount``, a positive magnitude.
    net : Money
        ``income - spending``, signed.
    transaction_count : int
        How many transactions were considered for this currency, regardless of
        whether they contributed to ``spending``, ``income``, or neither.
    average_daily_spending : Money or None
        ``spending`` divided by elapsed days in the period — see
        :func:`_average_daily_spending`. ``None`` when it cannot be derived
        (no ``period_start``, or an open period with no ``now`` supplied).
    by_category : tuple[CategoryGroupSummary, ...]
        This currency's totals partitioned by category root, each with its
        children rolled up. Sums to this summary's own
        ``spending``/``income``/``transaction_count``.
    by_bucket : tuple[BucketSummary, ...]
        This currency's totals partitioned by time bucket. Gap-filled across
        the full requested period when both bounds were given to
        :func:`summarize`; otherwise only buckets with a transaction. A
        transaction with neither ``booked_at`` nor ``value_date`` set is
        excluded here while still counted in this summary's own totals — the
        one place ``by_bucket`` does **not** sum back to the parent.
    by_account : tuple[AccountSummary, ...]
        This currency's totals partitioned by account. Sums to this summary's
        own totals.
    comparison : ComparisonSummary or None
        The comparison period's totals and the delta from them, or ``None``
        when no comparison was requested. Never set by :func:`summarize`
        itself — attached by the caller via
        :func:`compare`/:func:`summarize_comparisons`.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    currency: CurrencyCode
    spending: Money
    income: Money
    net: Money
    transaction_count: int
    average_daily_spending: Money | None = None
    by_category: tuple[CategoryGroupSummary, ...] = ()
    by_bucket: tuple[BucketSummary, ...] = ()
    by_account: tuple[AccountSummary, ...] = ()
    comparison: ComparisonSummary | None = None


def summarize(
    transactions: Sequence[Transaction],
    *,
    advance_shares: Mapping[UUID, Money] | None = None,
    parents: Mapping[UUID, UUID | None] | None = None,
    granularity: BucketGranularity = BucketGranularity.DAY,
    tz: tzinfo = UTC,
    period_start: datetime | None = None,
    period_end: datetime | None = None,
    now: datetime | None = None,
) -> list[CurrencySummary]:
    """Return spending/income summaries, one per currency, from ``effective_amount``.

    Groups transactions by currency and never sums across them — a combined
    converted total is built separately and optionally (ADR 0021) — and within
    each currency splits
    :func:`~traccio.domain.effective_amount.effective_amount` into the
    ``spending``/``income`` magnitudes and their signed ``net``, then
    partitions by category root, time bucket, and account. Mirrors
    :func:`~traccio.domain.events.event_total`'s resolution of an advance's
    signed share: the caller resolves ``advance_shares`` (typically via
    :func:`~traccio.services.advances.spending_shares`) and passes them in.
    ``transactions`` is one period's worth — this function has no notion of
    "compare"; see :func:`compare` for that.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The transactions to summarize (already filtered to the period of
        interest by the caller).
    advance_shares : Mapping[UUID, Money] or None, optional
        For each member whose ``role`` is
        :attr:`~traccio.domain.enums.TransactionRole.ADVANCE`, its **signed**
        spending share, keyed by transaction id. Ignored for every other role.
    parents : Mapping[UUID, UUID | None] or None, optional
        Every category id the caller owns, mapped to its own ``parent_id``
        (``None`` for a root) — typically built from
        :func:`~traccio.db.repositories.list_categories`. A category id
        appearing in ``transactions`` but absent from this mapping (a rare
        delete race) is treated as its own root, degrading gracefully rather
        than raising.
    granularity : BucketGranularity, optional
        How ``by_bucket`` groups time. Defaults to one bucket per day.
    tz : tzinfo, optional
        The timezone bucketing happens in. Defaults to UTC, so omitting it
        reproduces the pre-timezone behavior exactly.
    period_start : datetime or None, optional
        Inclusive lower bound of the period, for gap-filling ``by_bucket`` and
        deriving ``average_daily_spending``. Should match whatever bound the
        caller used to fetch ``transactions``.
    period_end : datetime or None, optional
        Exclusive upper bound of the period, for the same two purposes as
        ``period_start``.
    now : datetime or None, optional
        The current instant, injected rather than read from the clock so this
        function stays pure and testable. Only consulted by
        ``average_daily_spending`` when ``period_end`` is ``None`` (an
        open-ended period) or in the future relative to it.

    Returns
    -------
    list[CurrencySummary]
        One entry per currency present in ``transactions``, sorted by currency
        code for a deterministic result. Empty if ``transactions`` is empty.
        Each entry's ``comparison`` is always ``None`` — see :func:`compare`.

    Raises
    ------
    ValueError
        If a member is an advance but its share is missing from
        ``advance_shares`` (propagated from ``effective_amount``). The message
        is stable and value-free.
    """
    shares = advance_shares or {}
    parent_of = parents or {}

    spending_by_currency: dict[str, int] = {}
    income_by_currency: dict[str, int] = {}
    count_by_currency: dict[str, int] = {}

    # Keyed by (currency, root_id, child_id). child_id is None for the root's
    # *direct* transactions; a real UUID names one child bucket. root_id is
    # None only for the "no category" bucket, which has no children.
    spending_by_group: dict[tuple[str, UUID | None, UUID | None], int] = {}
    income_by_group: dict[tuple[str, UUID | None, UUID | None], int] = {}
    count_by_group: dict[tuple[str, UUID | None, UUID | None], int] = {}

    spending_by_bucket: dict[tuple[str, date], int] = {}
    income_by_bucket: dict[tuple[str, date], int] = {}
    count_by_bucket: dict[tuple[str, date], int] = {}

    spending_by_account: dict[tuple[str, UUID], int] = {}
    income_by_account: dict[tuple[str, UUID], int] = {}
    count_by_account: dict[tuple[str, UUID], int] = {}

    for transaction in transactions:
        share = shares.get(transaction.id)
        effective = effective_amount(transaction, advance_own_share=share)
        currency = effective.currency

        category_id = effective_category(transaction)
        if category_id is None:
            root_id: UUID | None = None
            child_id: UUID | None = None
        else:
            parent_id = parent_of.get(category_id)
            if parent_id is None:
                root_id = category_id
                child_id = None
            else:
                root_id = parent_id
                child_id = category_id
        group_key = (currency, root_id, child_id)

        bucket = _bucket_of(transaction, granularity=granularity, tz=tz)
        bucket_key = (currency, bucket) if bucket is not None else None

        account_key = (currency, transaction.account_id)

        count_by_currency[currency] = count_by_currency.get(currency, 0) + 1
        count_by_group[group_key] = count_by_group.get(group_key, 0) + 1
        count_by_account[account_key] = count_by_account.get(account_key, 0) + 1
        if bucket_key is not None:
            count_by_bucket[bucket_key] = count_by_bucket.get(bucket_key, 0) + 1

        if effective.amount < 0:
            magnitude = -effective.amount
            spending_by_currency[currency] = spending_by_currency.get(currency, 0) + magnitude
            spending_by_group[group_key] = spending_by_group.get(group_key, 0) + magnitude
            spending_by_account[account_key] = spending_by_account.get(account_key, 0) + magnitude
            if bucket_key is not None:
                spending_by_bucket[bucket_key] = spending_by_bucket.get(bucket_key, 0) + magnitude
        elif effective.amount > 0:
            income_by_currency[currency] = income_by_currency.get(currency, 0) + effective.amount
            income_by_group[group_key] = income_by_group.get(group_key, 0) + effective.amount
            income_by_account[account_key] = (
                income_by_account.get(account_key, 0) + effective.amount
            )
            if bucket_key is not None:
                income_by_bucket[bucket_key] = (
                    income_by_bucket.get(bucket_key, 0) + effective.amount
                )

    def _category_group_summaries(currency: str) -> tuple[CategoryGroupSummary, ...]:
        root_ids = {r for (cur, r, _c) in count_by_group if cur == currency}
        groups: list[CategoryGroupSummary] = []
        for root_id in root_ids:
            direct_key = (currency, root_id, None)
            child_ids = {
                c
                for (cur, r, c) in count_by_group
                if cur == currency and r == root_id and c is not None
            }
            children = tuple(
                sorted(
                    (
                        CategorySummary(
                            category_id=child_id,
                            spending=Money(
                                amount=spending_by_group.get((currency, root_id, child_id), 0),
                                currency=currency,
                            ),
                            income=Money(
                                amount=income_by_group.get((currency, root_id, child_id), 0),
                                currency=currency,
                            ),
                            transaction_count=count_by_group[(currency, root_id, child_id)],
                        )
                        for child_id in child_ids
                    ),
                    key=lambda e: (-e.spending.amount, -e.income.amount, str(e.category_id)),
                )
            )
            direct_spending = spending_by_group.get(direct_key, 0)
            direct_income = income_by_group.get(direct_key, 0)
            direct_count = count_by_group.get(direct_key, 0)
            total_spending = direct_spending + sum(c.spending.amount for c in children)
            total_income = direct_income + sum(c.income.amount for c in children)
            total_count = direct_count + sum(c.transaction_count for c in children)
            groups.append(
                CategoryGroupSummary(
                    category_id=root_id,
                    spending=Money(amount=total_spending, currency=currency),
                    income=Money(amount=total_income, currency=currency),
                    transaction_count=total_count,
                    direct_spending=Money(amount=direct_spending, currency=currency),
                    direct_income=Money(amount=direct_income, currency=currency),
                    direct_transaction_count=direct_count,
                    children=children,
                )
            )
        groups.sort(key=lambda g: (-g.spending.amount, -g.income.amount, str(g.category_id or "")))
        return tuple(groups)

    def _bucket_summaries(currency: str, grid: list[date] | None) -> tuple[BucketSummary, ...]:
        starts = (
            grid
            if grid is not None
            else sorted(b for (cur, b) in count_by_bucket if cur == currency)
        )
        return tuple(
            BucketSummary(
                start=start,
                end=_bucket_end(start, granularity),
                spending=Money(
                    amount=spending_by_bucket.get((currency, start), 0), currency=currency
                ),
                income=Money(amount=income_by_bucket.get((currency, start), 0), currency=currency),
                transaction_count=count_by_bucket.get((currency, start), 0),
            )
            for start in starts
        )

    def _account_summaries(currency: str) -> tuple[AccountSummary, ...]:
        account_ids = {a for (cur, a) in count_by_account if cur == currency}
        entries = [
            AccountSummary(
                account_id=account_id,
                spending=Money(
                    amount=spending_by_account.get((currency, account_id), 0), currency=currency
                ),
                income=Money(
                    amount=income_by_account.get((currency, account_id), 0), currency=currency
                ),
                transaction_count=count_by_account[(currency, account_id)],
            )
            for account_id in account_ids
        ]
        entries.sort(key=lambda e: (-e.spending.amount, -e.income.amount, str(e.account_id)))
        return tuple(entries)

    grid = _bucket_grid(
        period_start=period_start, period_end=period_end, granularity=granularity, tz=tz
    )
    currencies = set(count_by_currency)
    return [
        CurrencySummary(
            currency=currency,
            spending=Money(amount=spending_by_currency.get(currency, 0), currency=currency),
            income=Money(amount=income_by_currency.get(currency, 0), currency=currency),
            net=Money(
                amount=income_by_currency.get(currency, 0) - spending_by_currency.get(currency, 0),
                currency=currency,
            ),
            transaction_count=count_by_currency[currency],
            average_daily_spending=_average_daily_spending(
                Money(amount=spending_by_currency.get(currency, 0), currency=currency),
                period_start=period_start,
                period_end=period_end,
                now=now,
            ),
            by_category=_category_group_summaries(currency),
            by_bucket=_bucket_summaries(currency, grid),
            by_account=_account_summaries(currency),
        )
        for currency in sorted(currencies)
    ]


def compare(*, current: CurrencySummary, previous: CurrencySummary) -> ComparisonSummary:
    """Compare ``current``'s spending against ``previous``'s, same currency.

    Pure pairing of two already-computed :class:`CurrencySummary` totals — the
    caller is responsible for computing ``previous`` via a second
    :func:`summarize` call over the comparison period, and for matching
    currencies (see :func:`summarize_comparisons`).

    Parameters
    ----------
    current : CurrencySummary
        The period being shown.
    previous : CurrencySummary
        The comparison period, same currency as ``current``.

    Returns
    -------
    ComparisonSummary
        ``previous``'s own totals, plus the delta from ``previous`` to
        ``current``.
    """
    delta = current.spending.amount - previous.spending.amount
    pct = None if previous.spending.amount == 0 else delta / previous.spending.amount
    return ComparisonSummary(
        spending=previous.spending,
        income=previous.income,
        net=previous.net,
        spending_delta=Money(amount=delta, currency=current.currency),
        spending_delta_pct=pct,
    )


def summarize_comparisons(
    current: Sequence[CurrencySummary], previous: Sequence[CurrencySummary]
) -> dict[str, ComparisonSummary]:
    """Pair each ``current`` entry with its same-currency ``previous`` counterpart.

    A currency present in ``current`` but absent from ``previous`` (no
    spending at all in the comparison period) still gets a
    :class:`ComparisonSummary`: the comparison period's totals are all zero,
    so ``spending_delta`` equals the current period's full spending and
    ``spending_delta_pct`` is ``None`` (zero base, per :func:`compare`).

    Parameters
    ----------
    current : Sequence[CurrencySummary]
        The period being shown, one entry per currency.
    previous : Sequence[CurrencySummary]
        The comparison period, one entry per currency.

    Returns
    -------
    dict[str, ComparisonSummary]
        One entry per currency in ``current``, keyed by currency code.
    """
    previous_by_currency = {p.currency: p for p in previous}
    result: dict[str, ComparisonSummary] = {}
    for entry in current:
        prior = previous_by_currency.get(entry.currency)
        if prior is None:
            prior = CurrencySummary(
                currency=entry.currency,
                spending=Money(amount=0, currency=entry.currency),
                income=Money(amount=0, currency=entry.currency),
                net=Money(amount=0, currency=entry.currency),
                transaction_count=0,
            )
        result[entry.currency] = compare(current=entry, previous=prior)
    return result
