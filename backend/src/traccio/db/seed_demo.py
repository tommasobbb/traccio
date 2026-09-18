"""Seed a full, presentable synthetic dataset for a demo run.

``seed_dev.py`` gives ``GET /accounts`` something to return, but zero
transactions — every screen is empty on a fresh clone. This builds on the same
dev user, connection, and accounts (calling :func:`traccio.db.seed_dev.seed_dev`
first) and adds three months of transactions across a EUR current/savings pair,
a USD card, and a manual cash account: categorized spending and income, an
event with three member transactions, an advance with one participant and a
partial reimbursement, and an unlinked same-amount opposite-sign pair for the
transfer-suggestion detector to find. All values are synthetic (see
``.claude/rules/data-safety.md``): invented merchants, round amounts, no real
bank ever touched.

Idempotent — every row has a fixed id (derived from a name via ``uuid5``, not
random) and is merged, not inserted, so re-running changes nothing except
shifting the relative dates to stay "a few months of recent activity" as of
whenever it runs.

Run with ``make demo`` (works against SQLite out of the box — see
``backend/.env.example``).
"""

from datetime import UTC, date, datetime, timedelta
from uuid import UUID, uuid5

from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.mappers import (
    advance_to_row,
    event_to_row,
    participant_to_row,
    reimbursement_to_row,
    transaction_to_row,
)
from traccio.db.models import AccountRow, TransactionRow
from traccio.db.repositories import list_categories
from traccio.db.seed_dev import ACCOUNT_CURRENT_ID, ACCOUNT_SAVINGS_ID, CONNECTION_ID, seed_dev
from traccio.db.session import session_scope
from traccio.domain.enums import AccountKind, KeyStrategy, TransactionRole, TransactionStatus
from traccio.domain.models import Advance, Event, Participant, Reimbursement, Transaction
from traccio.domain.money import Money

logger = get_logger(__name__)

# Every demo id is derived from a stable name, not hand-picked hex — readable
# at the call site and impossible to accidentally collide between entities.
_NAMESPACE = UUID("d3f1b2a4-6e7c-4b8a-9d2e-1a2b3c4d5e6f")


def _id(name: str) -> UUID:
    return uuid5(_NAMESPACE, f"traccio-demo:{name}")


ACCOUNT_USD_CARD_ID = _id("account:usd-card")
ACCOUNT_CASH_ID = _id("account:cash")
EVENT_TRIP_ID = _id("event:trip-01")
ADVANCE_ID = _id("advance:restaurant-03")
PARTICIPANT_ID = _id("participant:person-01")
REIMBURSEMENT_ID = _id("reimbursement:person-01-partial")


def _txn(
    *,
    name: str,
    user_id: UUID,
    account_id: UUID,
    amount: int,
    currency: str,
    when: datetime,
    description: str,
    category_id: UUID | None = None,
    role: TransactionRole = TransactionRole.PERSONAL,
    manual: bool = False,
    event_id: UUID | None = None,
) -> TransactionRow:
    """Build one synthetic, categorized transaction row.

    ``manual`` picks the key strategy: a hand-entered movement on the cash
    account has no bank reference to key off (``KeyStrategy.MANUAL``,
    ``stable_key`` is its own id), everything else pretends to be
    provider-sourced (``KeyStrategy.ENTRY_REFERENCE``). Either way the key is
    derived from ``name``, so re-running this module can never duplicate a row.
    """
    txn_id = _id(f"transaction:{name}")
    entry_reference = None if manual else f"demo:{name}"
    stable_key = str(txn_id) if manual else f"demo:{name}"
    transaction = Transaction(
        id=txn_id,
        user_id=user_id,
        account_id=account_id,
        money=Money(amount=amount, currency=currency),
        booked_at=when,
        value_date=when,
        description=description,
        status=TransactionStatus.BOOKED,
        role=role,
        entry_reference=entry_reference,
        stable_key=stable_key,
        key_strategy=KeyStrategy.MANUAL if manual else KeyStrategy.ENTRY_REFERENCE,
    )
    row = transaction_to_row(transaction)
    # transaction_to_row deliberately never writes a category id or event_id —
    # see its own docstring — so both are set here, the same as an explicit
    # user action would.
    row.confirmed_category_id = category_id
    row.event_id = event_id
    return row


def seed_demo() -> None:
    """Insert (or refresh) a full demo dataset on top of ``seed_dev``'s state."""
    seed_dev()
    settings = get_settings()
    user_id = settings.dev_user_id
    now = datetime.now(UTC)

    def days_ago(n: int) -> datetime:
        return now - timedelta(days=n)

    with session_scope() as session:
        categories = {c.name: c.id for c in list_categories(session, user_id)}

        session.merge(
            AccountRow(
                id=ACCOUNT_USD_CARD_ID,
                user_id=user_id,
                connection_id=CONNECTION_ID,
                kind=AccountKind.CARD,
                currency="USD",
                identification_hash="dev-acct-usdcard-01",
                name="TEST US CARD 01",
                created_at=now,
            )
        )
        session.merge(
            AccountRow(
                id=ACCOUNT_CASH_ID,
                user_id=user_id,
                connection_id=None,
                kind=AccountKind.CASH,
                currency="EUR",
                identification_hash=None,
                name="TEST CASH 01",
                created_at=now,
            )
        )

        rows: list[TransactionRow] = []
        for month in range(3):  # 0 = this month, 2 = two months ago
            base = month * 30
            rows += [
                _txn(
                    name=f"salary-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_CURRENT_ID,
                    amount=250_000,
                    currency="EUR",
                    when=days_ago(base + 2),
                    description="TEST EMPLOYER SRL",
                    category_id=categories.get("Income"),
                ),
                _txn(
                    name=f"rent-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_CURRENT_ID,
                    amount=-85_000,
                    currency="EUR",
                    when=days_ago(base + 1),
                    description="TEST LANDLORD SRL",
                    category_id=categories.get("Rent"),
                ),
                _txn(
                    name=f"streaming-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_CURRENT_ID,
                    amount=-1_299,
                    currency="EUR",
                    when=days_ago(base + 4),
                    description="TEST STREAMFLIX",
                    category_id=categories.get("Streaming"),
                ),
                _txn(
                    name=f"utilities-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_CURRENT_ID,
                    amount=-7_500,
                    currency="EUR",
                    when=days_ago(base + 6),
                    description="TEST UTILITY CO",
                    category_id=categories.get("Utilities"),
                ),
                _txn(
                    name=f"fuel-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_CURRENT_ID,
                    amount=-6_000,
                    currency="EUR",
                    when=days_ago(base + 14),
                    description="TEST FUEL STATION 01",
                    category_id=categories.get("Fuel"),
                ),
                _txn(
                    name=f"usd-subscription-{month}",
                    user_id=user_id,
                    account_id=ACCOUNT_USD_CARD_ID,
                    amount=-999,
                    currency="USD",
                    when=days_ago(base + 7),
                    description="TEST CLOUD SERVICE INC",
                    category_id=categories.get("Subscriptions"),
                ),
            ]
            for i, offset in enumerate((5, 12, 19, 26)):
                rows.append(
                    _txn(
                        name=f"groceries-{month}-{i}",
                        user_id=user_id,
                        account_id=ACCOUNT_CURRENT_ID,
                        amount=-(3_800 + i * 900),
                        currency="EUR",
                        when=days_ago(base + offset),
                        description=f"TEST SUPERMARKET 0{(i % 2) + 1}",
                        category_id=categories.get("Groceries"),
                    )
                )
            for i, offset in enumerate((10, 24)):
                rows.append(
                    _txn(
                        name=f"coffee-{month}-{i}",
                        user_id=user_id,
                        account_id=ACCOUNT_CURRENT_ID,
                        amount=-280,
                        currency="EUR",
                        when=days_ago(base + offset),
                        description="TEST CAFE 01",
                        category_id=categories.get("Coffee"),
                    )
                )

        # Event: a short trip, three member transactions (item 32's "un evento").
        # Larger days_ago == further in the past, so the earliest calendar date
        # (booking the travel) gets the largest offset and the latest (the
        # trip's last dinner) gets the smallest.
        trip_start = days_ago(30 + 17)
        trip_end = days_ago(30 + 15)
        rows += [
            _txn(
                name="event-travel",
                user_id=user_id,
                account_id=ACCOUNT_CURRENT_ID,
                amount=-9_000,
                currency="EUR",
                when=trip_start,
                description="TEST TRAVEL AGENCY 01",
                category_id=categories.get("Travel"),
                event_id=EVENT_TRIP_ID,
            ),
            _txn(
                name="event-hotel",
                user_id=user_id,
                account_id=ACCOUNT_CURRENT_ID,
                amount=-18_000,
                currency="EUR",
                when=days_ago(30 + 16),
                description="TEST HOTEL 01",
                category_id=categories.get("Travel"),
                event_id=EVENT_TRIP_ID,
            ),
            _txn(
                name="event-dinner",
                user_id=user_id,
                account_id=ACCOUNT_CURRENT_ID,
                amount=-6_500,
                currency="EUR",
                when=trip_end,
                description="TEST RESTAURANT 04",
                category_id=categories.get("Dining out"),
                event_id=EVENT_TRIP_ID,
            ),
        ]
        event = Event(
            id=EVENT_TRIP_ID,
            user_id=user_id,
            name="TEST TRIP 01",
            emoji="\U0001f9f3",  # 🧳
            start_date=date(trip_start.year, trip_start.month, trip_start.day),
            end_date=date(trip_end.year, trip_end.month, trip_end.day),
            created_at=trip_start,
        )
        session.merge(event_to_row(event))

        # Advance with one participant, partially reimbursed (item 32's "un
        # anticipo con rimborso parziale") — the receivable is 6000 (9000 -
        # the user's own 3000 share); only 3000 of it has been paid back, so
        # the participant stays "outstanding" rather than "settled".
        advance_txn_when = days_ago(20)
        rows.append(
            _txn(
                name="advance-restaurant",
                user_id=user_id,
                account_id=ACCOUNT_CURRENT_ID,
                amount=-9_000,
                currency="EUR",
                when=advance_txn_when,
                description="TEST RESTAURANT 03",
                category_id=categories.get("Dining out"),
                role=TransactionRole.ADVANCE,
            )
        )
        advance = Advance(
            id=ADVANCE_ID,
            user_id=user_id,
            transaction_id=_id("transaction:advance-restaurant"),
            own_share=Money(amount=3_000, currency="EUR"),
            participants=[
                Participant(
                    id=PARTICIPANT_ID,
                    name="TEST PERSON 01",
                    expected_amount=Money(amount=6_000, currency="EUR"),
                )
            ],
            created_at=advance_txn_when,
        )
        session.merge(advance_to_row(advance))
        session.merge(
            participant_to_row(advance.participants[0], user_id=user_id, advance_id=ADVANCE_ID)
        )
        reimbursement = Reimbursement(
            id=REIMBURSEMENT_ID,
            user_id=user_id,
            advance_id=ADVANCE_ID,
            amount=Money(amount=3_000, currency="EUR"),
            transaction_id=None,  # a manual cash repayment, not a bank transfer
            participant_id=PARTICIPANT_ID,
            note="Partial repayment, cash",
            created_at=days_ago(10),
        )
        session.merge(reimbursement_to_row(reimbursement))

        # Unlinked transfer pair (item 32's "una coppia di trasferimento da
        # rilevare") — same amount, opposite signs, four days apart at most
        # (the default detection window), both still `personal`, so
        # GET /transfers/suggestions finds it rather than it being pre-linked.
        rows += [
            _txn(
                name="transfer-out",
                user_id=user_id,
                account_id=ACCOUNT_CURRENT_ID,
                amount=-20_000,
                currency="EUR",
                when=days_ago(9),
                description="TEST INTERNAL TRANSFER",
            ),
            _txn(
                name="transfer-in",
                user_id=user_id,
                account_id=ACCOUNT_SAVINGS_ID,
                amount=20_000,
                currency="EUR",
                when=days_ago(9),
                description="TEST INTERNAL TRANSFER",
            ),
        ]

        # Manual cash account (ADR 0020) — hand-entered movements, no sync.
        rows += [
            _txn(
                name="cash-purchase-1",
                user_id=user_id,
                account_id=ACCOUNT_CASH_ID,
                amount=-1_500,
                currency="EUR",
                when=days_ago(11),
                description="TEST CASH PURCHASE 01",
                category_id=categories.get("Groceries"),
                manual=True,
            ),
            _txn(
                name="cash-purchase-2",
                user_id=user_id,
                account_id=ACCOUNT_CASH_ID,
                amount=-2_000,
                currency="EUR",
                when=days_ago(21),
                description="TEST CASH PURCHASE 02",
                category_id=categories.get("Dining out"),
                manual=True,
            ),
        ]

        for row in rows:
            session.merge(row)

    logger.info("seed_demo.done", transactions=len(rows), accounts=4)


if __name__ == "__main__":
    seed_demo()
