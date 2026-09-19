"""One-off repair for terminal transaction rows a mapper fix cannot reach.

``upsert_transaction`` (``db/repositories.py``) returns an existing
``booked``/``rejected`` row **untouched** by design — terminal rows are
immutable (``docs/domain.md``, ``docs/decisions/0019-...``). So the
2026-08-27 mapper fix for PayPal's missing ``booked_at``/``value_date``/
``description`` (``providers/enable_banking/transactions.py``) only helps
transactions synced *after* the fix; the rows already persisted with those
fields empty stay empty forever unless something re-fetches and fills them.

This script is that something. For one connection, it:

1. Finds every terminal row with at least one empty repairable field
   (``booked_at`` or ``value_date`` is ``NULL``, or ``description`` is
   ``""``).
2. Re-fetches transactions for the connection's accounts through
   :meth:`~traccio.providers.base.BankProvider.fetch_transactions` — the
   *same* path a normal sync uses, so field mapping cannot drift between the
   two.
3. Matches a stored row to a freshly-fetched one by ``stable_key`` (the same
   identity ``upsert_transaction``'s unique constraint uses).
4. Fills only a field that is empty on the stored row *and* populated on the
   fresh one. Never overwrites a populated field, and never touches
   ``amount``, ``currency``, ``status``, ``entry_reference``,
   ``key_strategy``, ``role``, ``display_description``, ``event_id``, or
   either category id — those are out of scope, immutability's real job.

Not PayPal-specific: it repairs any account served through
:func:`~traccio.api.deps.build_bank_provider`, whatever bank sent the empty
fields (`docs/engineering.md`: no per-bank branching outside the adapter
seam).

**The bank will not serve everything.** PayPal (like most Open Banking
providers) only serves a rolling history window after the initial
post-authorization grant — accepted knowingly, see
``docs/decisions/0019-repairing-incomplete-synced-transactions.md``. A row
whose ``stable_key`` the bank no longer returns stays empty; the report's
``rows_unmatched`` count is that ceiling made visible, not a bug in this
script.

``--dry-run`` behavior is the default: nothing is written unless ``--apply``
is passed. Idempotent — a second ``--apply`` run reports ``rows_updated=0``.

Run with ``make repair-empty-fields CONNECTION=<connection-id>`` (add
``APPLY=1`` to write). Needs the same environment as ``eb_field_census.py``:
``TRACCIO_ENABLE_BANKING_*``, ``TRACCIO_ENCRYPTION_KEY``,
``TRACCIO_DATABASE_URL``.

Data safety (`docs/engineering.md`): same guard as
``eb_field_census.py`` — nothing derived from a value is ever printed. The
report is counts only: how many rows, how many fields filled, how many still
empty. No description, no date, no counterparty name ever reaches stdout.
"""

import argparse
import sys
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from traccio.api.deps import build_bank_provider
from traccio.core.config import get_settings
from traccio.core.crypto import get_token_cipher
from traccio.db.mappers import row_to_account
from traccio.db.models import AccountRow, TransactionRow
from traccio.db.repositories import get_connection_credentials
from traccio.db.session import session_scope
from traccio.domain.enums import TransactionStatus
from traccio.domain.models import Account, Transaction
from traccio.providers.base import BankProvider, ProviderError, SyncContext

# The three fields the 2026-08-27 mapper fix can populate that a terminal row
# may still be missing. Order also drives the report's field-by-field lines.
_REPAIRABLE = ("booked_at", "value_date", "description")


@dataclass(frozen=True, slots=True)
class StoredTransactionFields:
    """The subset of a persisted row :func:`plan_repair` needs to decide a fill.

    A plain dataclass, not the SQLAlchemy row, so :func:`plan_repair` stays a
    pure function testable with no database.
    """

    id: UUID
    stable_key: str
    booked_at: datetime | None
    value_date: datetime | None
    description: str


@dataclass(frozen=True, slots=True)
class RepairPlan:
    """What :func:`plan_repair` decided, before anything is written.

    Attributes
    ----------
    updates : dict[UUID, dict[str, datetime or str]]
        Per stored row id, only the fields to actually write.
    rows_matched : int
        Stored rows for which a fresh transaction with the same
        ``stable_key`` was found (whether or not it filled anything).
    rows_unmatched : int
        Stored rows the bank no longer serves — the history-window ceiling.
    filled : Counter[str]
        Per field, how many rows got it filled.
    still_empty : Counter[str]
        Per field, how many rows remain empty (unmatched, or matched but the
        fresh value was itself empty).
    """

    updates: dict[UUID, dict[str, datetime | str]]
    rows_matched: int
    rows_unmatched: int
    filled: Counter[str]
    still_empty: Counter[str]


@dataclass(frozen=True, slots=True)
class RepairReport:
    """The printable outcome of repairing one account, or several combined.

    Attributes
    ----------
    rows_stored : int
        Terminal rows found with at least one empty repairable field.
    entries_fetched : int
        Transactions re-fetched from the bank for comparison.
    rows_matched, rows_unmatched : int
        See :class:`RepairPlan`.
    filled, still_empty : Counter[str]
        See :class:`RepairPlan`.
    rows_updated : int
        Rows with at least one field filled — written only when the caller
        ran with ``apply=True``; otherwise what *would* be written.
    """

    rows_stored: int
    entries_fetched: int
    rows_matched: int
    rows_unmatched: int
    filled: Counter[str] = field(default_factory=Counter)
    still_empty: Counter[str] = field(default_factory=Counter)
    rows_updated: int = 0


def _empty_fields(row: StoredTransactionFields) -> list[str]:
    """Which of :data:`_REPAIRABLE` are currently empty on this stored row."""
    empty = []
    if row.booked_at is None:
        empty.append("booked_at")
    if row.value_date is None:
        empty.append("value_date")
    if row.description == "":
        empty.append("description")
    return empty


def _candidate(fresh: Transaction, field_name: str) -> datetime | str | None:
    """The freshly-fetched value for one repairable field, or ``None``/``""``."""
    if field_name == "booked_at":
        return fresh.booked_at
    if field_name == "value_date":
        return fresh.value_date
    if field_name == "description":
        return fresh.description
    raise ValueError("unknown repairable field")  # unreachable: callers only pass _REPAIRABLE


def plan_repair(
    stored: Sequence[StoredTransactionFields],
    fresh_by_key: Mapping[str, Transaction],
) -> RepairPlan:
    """Decide, for each stored row, which empty fields a fresh fetch can fill.

    Pure and I/O-free: the caller has already fetched ``fresh_by_key``
    (keyed by ``stable_key``, scoped to one account) and read ``stored`` from
    the database. Never proposes overwriting a field that is already
    populated, and never proposes a fill from a fresh value that is itself
    empty — the honest outcome there is "still empty", not a guess.

    Parameters
    ----------
    stored : Sequence[StoredTransactionFields]
        Rows to consider, already filtered to ones with at least one empty
        repairable field.
    fresh_by_key : Mapping[str, Transaction]
        Freshly re-fetched transactions for the same account, keyed by
        ``stable_key``.

    Returns
    -------
    RepairPlan
        The per-row updates to apply, plus counts for the report.
    """
    updates: dict[UUID, dict[str, datetime | str]] = {}
    rows_matched = 0
    rows_unmatched = 0
    filled: Counter[str] = Counter()
    still_empty: Counter[str] = Counter()

    for row in stored:
        empty_fields = _empty_fields(row)
        fresh = fresh_by_key.get(row.stable_key)
        if fresh is None:
            rows_unmatched += 1
            still_empty.update(empty_fields)
            continue

        rows_matched += 1
        row_updates: dict[str, datetime | str] = {}
        for field_name in empty_fields:
            candidate = _candidate(fresh, field_name)
            if candidate is None or candidate == "":
                still_empty[field_name] += 1
                continue
            row_updates[field_name] = candidate
            filled[field_name] += 1
        if row_updates:
            updates[row.id] = row_updates

    return RepairPlan(
        updates=updates,
        rows_matched=rows_matched,
        rows_unmatched=rows_unmatched,
        filled=filled,
        still_empty=still_empty,
    )


def repair_account(
    session: Session,
    *,
    provider: BankProvider,
    credentials: str,
    account: Account,
    days: int,
    now: datetime,
    apply: bool,
) -> RepairReport:
    """Repair one account's terminal rows with an empty repairable field.

    Parameters
    ----------
    session : Session
        Active database session. Not committed here — the caller (``main``,
        via :func:`~traccio.db.session.session_scope`) owns that boundary.
    provider : BankProvider
        The bank adapter to re-fetch through.
    credentials : str
        The decrypted consent secret for this account's connection.
    account : Account
        The account to repair.
    days : int
        How far back to re-fetch. The bank may serve less regardless (see
        the module docstring) — that shows up as ``rows_unmatched``.
    now : datetime
        Current time, timezone-aware; the window's upper bound is "now".
    apply : bool
        Whether to actually write the filled fields onto the ORM rows (the
        caller commits). When ``False``, nothing is mutated.

    Returns
    -------
    RepairReport
        Counts only — see :class:`RepairReport`.
    """
    stored_rows = session.scalars(
        select(TransactionRow).where(
            TransactionRow.account_id == account.id,
            TransactionRow.status != TransactionStatus.PENDING,
            or_(
                TransactionRow.booked_at.is_(None),
                TransactionRow.value_date.is_(None),
                TransactionRow.description == "",
            ),
        )
    ).all()
    if not stored_rows:
        return RepairReport(rows_stored=0, entries_fetched=0, rows_matched=0, rows_unmatched=0)

    stored = [
        StoredTransactionFields(
            id=row.id,
            stable_key=row.stable_key,
            booked_at=row.booked_at,
            value_date=row.value_date,
            description=row.description,
        )
        for row in stored_rows
    ]

    since = now - timedelta(days=days)
    fresh = provider.fetch_transactions(
        credentials=credentials,
        account=account,
        since=since,
        until=None,
        context=SyncContext(psu_present=True),
    )
    fresh_by_key = {tx.stable_key: tx for tx in fresh}

    plan = plan_repair(stored, fresh_by_key)

    if apply and plan.updates:
        rows_by_id = {row.id: row for row in stored_rows}
        for row_id, fields in plan.updates.items():
            target = rows_by_id[row_id]
            for field_name, value in fields.items():
                setattr(target, field_name, value)

    return RepairReport(
        rows_stored=len(stored),
        entries_fetched=len(fresh),
        rows_matched=plan.rows_matched,
        rows_unmatched=plan.rows_unmatched,
        filled=plan.filled,
        still_empty=plan.still_empty,
        rows_updated=len(plan.updates),
    )


def _merge(a: RepairReport, b: RepairReport) -> RepairReport:
    """Combine two account-level reports into one connection-level total."""
    return RepairReport(
        rows_stored=a.rows_stored + b.rows_stored,
        entries_fetched=a.entries_fetched + b.entries_fetched,
        rows_matched=a.rows_matched + b.rows_matched,
        rows_unmatched=a.rows_unmatched + b.rows_unmatched,
        filled=a.filled + b.filled,
        still_empty=a.still_empty + b.still_empty,
        rows_updated=a.rows_updated + b.rows_updated,
    )


def render(report: RepairReport, *, apply: bool) -> list[str]:
    """Render the report as printable lines. No value ever appears."""
    rows_updated_label = "rows updated" if apply else "rows that would be updated"
    lines = [
        f"mode: {'apply' if apply else 'dry-run (pass --apply to write)'}",
        f"rows with an empty repairable field:         {report.rows_stored}",
        f"transaction entries re-fetched:               {report.entries_fetched}",
        f"rows matched by stable_key:                   {report.rows_matched}",
        f"rows unmatched (bank no longer serves them):  {report.rows_unmatched}",
        f"{rows_updated_label}:{' ' * (46 - len(rows_updated_label))}{report.rows_updated}",
        "",
        "filled per field:",
    ]
    for field_name in _REPAIRABLE:
        lines.append(f"  {field_name:<14} {report.filled.get(field_name, 0)}")
    lines.append("")
    lines.append("still empty per field (unmatched, or the bank has no value either):")
    for field_name in _REPAIRABLE:
        lines.append(f"  {field_name:<14} {report.still_empty.get(field_name, 0)}")
    return lines


def _accounts_for_connection(
    session: Session, *, user_id: UUID, connection_id: UUID
) -> list[Account]:
    rows = session.scalars(
        select(AccountRow).where(
            AccountRow.user_id == user_id, AccountRow.connection_id == connection_id
        )
    ).all()
    return [row_to_account(row) for row in rows]


def main() -> int:
    """Run the repair. See the module docstring for scope and safety.

    Returns
    -------
    int
        Process exit code: ``0`` on success, ``1`` on a missing credential,
        no synced accounts, or a provider error (message kept value-free).
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument("--connection-id", required=True, help="Connection UUID to repair.")
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="How far back to re-fetch (default: Settings.initial_history_days; "
        "the bank may serve less regardless, see the module docstring).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the filled fields. Without this flag, only a dry-run report is printed.",
    )
    args = parser.parse_args()

    settings = get_settings()
    days = args.days if args.days is not None else settings.initial_history_days
    now = datetime.now(UTC)
    connection_id = UUID(args.connection_id)

    provider, client = build_bank_provider()
    try:
        with session_scope() as session:
            encrypted = get_connection_credentials(
                session, user_id=settings.dev_user_id, connection_id=connection_id
            )
            if encrypted is None:
                print("connection has no active, usable credentials", file=sys.stderr)
                return 1
            cipher = get_token_cipher(settings.encryption_key)
            credentials = cipher.decrypt(encrypted)

            accounts = _accounts_for_connection(
                session, user_id=settings.dev_user_id, connection_id=connection_id
            )
            if not accounts:
                print("connection has no synced accounts", file=sys.stderr)
                return 1

            total = RepairReport(rows_stored=0, entries_fetched=0, rows_matched=0, rows_unmatched=0)
            for account in accounts:
                report = repair_account(
                    session,
                    provider=provider,
                    credentials=credentials,
                    account=account,
                    days=days,
                    now=now,
                    apply=args.apply,
                )
                total = _merge(total, report)
    except ProviderError as exc:
        print(f"Enable Banking request failed: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()

    for line in render(total, apply=args.apply):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
