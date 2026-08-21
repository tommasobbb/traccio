"""Tests for ``GET /transactions``.

The app is built via the factory and its ``get_session`` dependency is
overridden to a shared in-memory SQLite engine, so the endpoint is exercised end
to end (routing, response schema, repository query) without a running
PostgreSQL. Values are synthetic (see ``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.models import TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionRole, TransactionStatus


def _tx(
    *,
    user_id: UUID,
    account_id: UUID,
    stable_key: str,
    description: str,
    booked_at: datetime | None,
    value_date: datetime | None,
    status: TransactionStatus = TransactionStatus.BOOKED,
    role: TransactionRole = TransactionRole.PERSONAL,
    last_synced_at: datetime | None = None,
    event_id: UUID | None = None,
    confirmed_category_id: UUID | None = None,
) -> TransactionRow:
    """Build a synthetic transaction row for ``user_id``."""
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=account_id,
        amount=-1234,
        currency="EUR",
        booked_at=booked_at,
        value_date=value_date,
        description=description,
        display_description=None,
        status=status,
        role=role,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        last_synced_at=last_synced_at,
        event_id=event_id,
        confirmed_category_id=confirmed_category_id,
    )


def _client(engine: Engine) -> TestClient:
    """Build a client whose sessions come from ``engine``."""

    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    return TestClient(app)


def _sqlite_engine() -> Engine:
    """Create a fresh in-memory SQLite engine sharing one connection."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def test_transactions_returns_only_current_users_most_recent_first() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-OLD",
                    description="TEST MERCHANT OLD",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-NEW",
                    description="TEST MERCHANT NEW",
                    booked_at=datetime(2026, 3, 1, tzinfo=UTC),
                    value_date=datetime(2026, 3, 1, tzinfo=UTC),
                ),
                # Pending (no booked_at) — ordered by its value_date fallback,
                # which places it between the other two.
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-PENDING",
                    description="TEST MERCHANT PENDING",
                    booked_at=None,
                    value_date=datetime(2026, 2, 1, tzinfo=UTC),
                    status=TransactionStatus.PENDING,
                ),
                _tx(
                    user_id=stranger_id,
                    account_id=uuid4(),
                    stable_key="TX-STRANGER",
                    description="STRANGER MERCHANT",
                    booked_at=datetime(2026, 4, 1, tzinfo=UTC),
                    value_date=datetime(2026, 4, 1, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions")

    assert response.status_code == 200
    transactions = response.json()["transactions"]
    # Only the dev user's rows, most recent first; the stranger's is excluded.
    assert [t["description"] for t in transactions] == [
        "TEST MERCHANT NEW",
        "TEST MERCHANT PENDING",
        "TEST MERCHANT OLD",
    ]
    # Projection carries the client-facing fields and none of the internals.
    first = transactions[0]
    assert first["amount"] == -1234
    # A personal transaction's effective amount is its full amount.
    assert first["effective_amount"] == -1234
    assert first["currency"] == "EUR"
    assert first["role"] == "personal"
    assert "stable_key" not in first
    assert "user_id" not in first


def test_transactions_expose_zero_effective_amount_for_rejected() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=dev_user_id,
                account_id=account_id,
                stable_key="TX-RJCT",
                description="TEST MERCHANT REJECTED",
                booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                value_date=datetime(2026, 1, 1, tzinfo=UTC),
                status=TransactionStatus.REJECTED,
            )
        )
        session.commit()

    response = _client(engine).get("/transactions")

    assert response.status_code == 200
    row = response.json()["transactions"][0]
    # A rejected movement never settled: raw amount is preserved for balance
    # reconciliation, but it contributes zero effective spending.
    assert row["amount"] == -1234
    assert row["effective_amount"] == 0


def test_transactions_can_be_filtered_by_account() -> None:
    dev_user_id = get_settings().dev_user_id
    account_a = uuid4()
    account_b = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_a,
                    stable_key="TX-A",
                    description="TEST MERCHANT A",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_b,
                    stable_key="TX-B",
                    description="TEST MERCHANT B",
                    booked_at=datetime(2026, 2, 1, tzinfo=UTC),
                    value_date=datetime(2026, 2, 1, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"account_id": str(account_a)})

    assert response.status_code == 200
    transactions = response.json()["transactions"]
    assert [t["description"] for t in transactions] == ["TEST MERCHANT A"]


def test_transactions_paginate_with_limit_and_offset() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        # Three rows, newest last-inserted; expected order is 3, 2, 1.
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key=f"TX-{month}",
                    description=f"TEST MERCHANT {month}",
                    booked_at=datetime(2026, month, 1, tzinfo=UTC),
                    value_date=datetime(2026, month, 1, tzinfo=UTC),
                )
                for month in (1, 2, 3)
            ]
        )
        session.commit()

    client = _client(engine)
    page_one = client.get("/transactions", params={"limit": 2})
    page_two = client.get("/transactions", params={"limit": 2, "offset": 2})

    assert [t["description"] for t in page_one.json()["transactions"]] == [
        "TEST MERCHANT 3",
        "TEST MERCHANT 2",
    ]
    assert [t["description"] for t in page_two.json()["transactions"]] == ["TEST MERCHANT 1"]


def test_transactions_reject_out_of_range_limit() -> None:
    response = _client(_sqlite_engine()).get("/transactions", params={"limit": 0})

    # FastAPI validates the query bound (ge=1) before the handler runs.
    assert response.status_code == 422


def test_transactions_empty_when_user_has_none() -> None:
    response = _client(_sqlite_engine()).get("/transactions")

    assert response.status_code == 200
    assert response.json() == {"transactions": []}


def test_transactions_expose_null_category_ids_when_uncategorized() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=dev_user_id,
                account_id=uuid4(),
                stable_key="TX-A",
                description="TEST MERCHANT 01",
                booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                value_date=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()

    response = _client(engine).get("/transactions")

    row = response.json()["transactions"][0]
    assert row["suggested_category_id"] is None
    assert row["confirmed_category_id"] is None
    assert row["effective_category_id"] is None


# --- POST /transactions/prune-pending ----------------------------------------

_STALE = datetime(2020, 1, 1, tzinfo=UTC)  # far past pending_transaction_ttl_days
_FRESH = datetime.now(UTC)  # inside the window


def test_prune_pending_deletes_a_stale_eligible_transaction() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=dev_user_id,
                account_id=uuid4(),
                stable_key="TX-STALE",
                description="TEST MERCHANT STALE",
                booked_at=None,
                value_date=None,
                status=TransactionStatus.PENDING,
                last_synced_at=_STALE,
            )
        )
        session.commit()

    response = _client(engine).post("/transactions/prune-pending")

    assert response.status_code == 200
    assert response.json() == {"pruned": 1}
    assert _client(engine).get("/transactions").json() == {"transactions": []}


def test_prune_pending_leaves_ineligible_rows() -> None:
    """A row inside the window, still linked (role), assigned to an event, or
    carrying a confirmed category must all survive the same call."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-FRESH",
                    description="TEST MERCHANT FRESH",
                    booked_at=None,
                    value_date=None,
                    status=TransactionStatus.PENDING,
                    last_synced_at=_FRESH,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-NEVER-SYNCED",
                    description="TEST MERCHANT NEVER SYNCED",
                    booked_at=None,
                    value_date=None,
                    status=TransactionStatus.PENDING,
                    last_synced_at=None,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-TRANSFER",
                    description="TEST MERCHANT TRANSFER",
                    booked_at=None,
                    value_date=None,
                    status=TransactionStatus.PENDING,
                    # role != personal alone is proof of a link (see
                    # prune_stale_pending_transactions); transfer avoids
                    # needing a real Advance row just to render effective_amount.
                    role=TransactionRole.TRANSFER,
                    last_synced_at=_STALE,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-EVENT",
                    description="TEST MERCHANT EVENT",
                    booked_at=None,
                    value_date=None,
                    status=TransactionStatus.PENDING,
                    event_id=uuid4(),
                    last_synced_at=_STALE,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-CATEGORIZED",
                    description="TEST MERCHANT CATEGORIZED",
                    booked_at=None,
                    value_date=None,
                    status=TransactionStatus.PENDING,
                    confirmed_category_id=uuid4(),
                    last_synced_at=_STALE,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-BOOKED",
                    description="TEST MERCHANT BOOKED",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                    status=TransactionStatus.BOOKED,
                    last_synced_at=_STALE,
                ),
            ]
        )
        session.commit()

    response = _client(engine).post("/transactions/prune-pending")

    assert response.status_code == 200
    assert response.json() == {"pruned": 0}
    remaining = {
        t["description"] for t in _client(engine).get("/transactions").json()["transactions"]
    }
    assert remaining == {
        "TEST MERCHANT FRESH",
        "TEST MERCHANT NEVER SYNCED",
        "TEST MERCHANT TRANSFER",
        "TEST MERCHANT EVENT",
        "TEST MERCHANT CATEGORIZED",
        "TEST MERCHANT BOOKED",
    }


def test_prune_pending_is_user_scoped() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=stranger_id,
                account_id=uuid4(),
                stable_key="TX-STRANGER",
                description="STRANGER MERCHANT",
                booked_at=None,
                value_date=None,
                status=TransactionStatus.PENDING,
                last_synced_at=_STALE,
            )
        )
        session.commit()

    response = _client(engine).post("/transactions/prune-pending")

    # A stranger's stale pending row is invisible to the dev user's prune call.
    assert response.status_code == 200
    assert response.json() == {"pruned": 0}
