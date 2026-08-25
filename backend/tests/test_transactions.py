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
from traccio.db.models import CategoryRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, PaletteColor, TransactionRole, TransactionStatus


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
    display_description: str | None = None,
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
        display_description=display_description,
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


def test_transactions_can_be_filtered_by_event() -> None:
    dev_user_id = get_settings().dev_user_id
    event_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-IN-EVENT",
                    description="TEST MERCHANT IN EVENT",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                    event_id=event_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-NO-EVENT",
                    description="TEST MERCHANT NO EVENT",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"event_id": str(event_id)})

    assert response.status_code == 200
    transactions = response.json()["transactions"]
    assert [t["description"] for t in transactions] == ["TEST MERCHANT IN EVENT"]
    assert transactions[0]["event_id"] == str(event_id)


def test_transactions_event_id_is_null_when_unassigned() -> None:
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

    assert response.json()["transactions"][0]["event_id"] is None


def test_transactions_event_filter_is_user_scoped() -> None:
    """A stranger's event id (or one belonging to another user's transaction)
    must never leak that transaction to the current user."""
    stranger_id = uuid4()
    event_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=stranger_id,
                account_id=uuid4(),
                stable_key="TX-STRANGER",
                description="STRANGER MERCHANT",
                booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                value_date=datetime(2026, 1, 1, tzinfo=UTC),
                event_id=event_id,
            )
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"event_id": str(event_id)})

    assert response.status_code == 200
    assert response.json() == {"transactions": []}


def test_transactions_can_be_filtered_by_effective_category() -> None:
    dev_user_id = get_settings().dev_user_id
    category_id = uuid4()
    other_category_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                # Confirmed overrides suggested — the effective_category rule.
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-CONFIRMED",
                    description="TEST MERCHANT CONFIRMED",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                    confirmed_category_id=category_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-OTHER",
                    description="TEST MERCHANT OTHER",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                    confirmed_category_id=other_category_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-UNCATEGORIZED",
                    description="TEST MERCHANT UNCATEGORIZED",
                    booked_at=datetime(2026, 1, 3, tzinfo=UTC),
                    value_date=datetime(2026, 1, 3, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"category_id": str(category_id)})

    assert response.status_code == 200
    assert [t["description"] for t in response.json()["transactions"]] == [
        "TEST MERCHANT CONFIRMED"
    ]


def test_category_filter_includes_children() -> None:
    """Filtering on a root category rolls up its children too."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    root_id, child_id, other_id = uuid4(), uuid4(), uuid4()
    with Session(engine) as session:
        session.add_all(
            [
                CategoryRow(
                    id=root_id,
                    user_id=dev_user_id,
                    name="Housing",
                    color=PaletteColor.INDIGO,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                CategoryRow(
                    id=child_id,
                    user_id=dev_user_id,
                    name="Rent",
                    parent_id=root_id,
                    color=PaletteColor.INDIGO,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                CategoryRow(
                    id=other_id,
                    user_id=dev_user_id,
                    name="Transport",
                    color=PaletteColor.BLUE,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
            ]
        )
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-ROOT",
                    description="TEST MERCHANT ROOT",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                    confirmed_category_id=root_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-CHILD",
                    description="TEST MERCHANT CHILD",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                    confirmed_category_id=child_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-OTHER",
                    description="TEST MERCHANT OTHER",
                    booked_at=datetime(2026, 1, 3, tzinfo=UTC),
                    value_date=datetime(2026, 1, 3, tzinfo=UTC),
                    confirmed_category_id=other_id,
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"category_id": str(root_id)})

    assert response.status_code == 200
    descriptions = {t["description"] for t in response.json()["transactions"]}
    assert descriptions == {"TEST MERCHANT ROOT", "TEST MERCHANT CHILD"}


def test_category_filter_on_a_child_does_not_roll_up_to_siblings() -> None:
    """Filtering on a child returns only that child — no expansion upward."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    root_id, child_id, sibling_id = uuid4(), uuid4(), uuid4()
    with Session(engine) as session:
        session.add_all(
            [
                CategoryRow(
                    id=root_id,
                    user_id=dev_user_id,
                    name="Housing",
                    color=PaletteColor.INDIGO,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                CategoryRow(
                    id=child_id,
                    user_id=dev_user_id,
                    name="Rent",
                    parent_id=root_id,
                    color=PaletteColor.INDIGO,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                CategoryRow(
                    id=sibling_id,
                    user_id=dev_user_id,
                    name="Maintenance",
                    parent_id=root_id,
                    color=PaletteColor.INDIGO,
                    created_at=datetime(2026, 1, 1, tzinfo=UTC),
                ),
            ]
        )
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-CHILD",
                    description="TEST MERCHANT CHILD",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                    confirmed_category_id=child_id,
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-SIBLING",
                    description="TEST MERCHANT SIBLING",
                    booked_at=datetime(2026, 1, 3, tzinfo=UTC),
                    value_date=datetime(2026, 1, 3, tzinfo=UTC),
                    confirmed_category_id=sibling_id,
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"category_id": str(child_id)})

    assert response.status_code == 200
    assert [t["description"] for t in response.json()["transactions"]] == ["TEST MERCHANT CHILD"]


def test_transactions_can_be_filtered_to_uncategorized() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-CATEGORIZED",
                    description="TEST MERCHANT CATEGORIZED",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                    confirmed_category_id=uuid4(),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=uuid4(),
                    stable_key="TX-UNCATEGORIZED",
                    description="TEST MERCHANT UNCATEGORIZED",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"uncategorized": "true"})

    assert response.status_code == 200
    assert [t["description"] for t in response.json()["transactions"]] == [
        "TEST MERCHANT UNCATEGORIZED"
    ]


def test_transactions_rejects_conflicting_category_filters() -> None:
    response = _client(_sqlite_engine()).get(
        "/transactions", params={"category_id": str(uuid4()), "uncategorized": "true"}
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "conflicting_category_filter"


# --- GET /transactions?q= -----------------------------------------------------


def test_transactions_search_is_case_insensitive() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-MATCH",
                    description="TEST MERCHANT ESSELUNGA",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-NOMATCH",
                    description="TEST MERCHANT OTHER",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"q": "esselunga"})

    assert response.status_code == 200
    assert [t["description"] for t in response.json()["transactions"]] == [
        "TEST MERCHANT ESSELUNGA"
    ]


def test_transactions_search_matches_display_description_too() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=dev_user_id,
                account_id=account_id,
                stable_key="TX-CLEANED",
                description="RAW TEXT WITH REFS 998877",
                display_description="TEST MERCHANT CLEANED",
                booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                value_date=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"q": "cleaned"})

    assert response.status_code == 200
    assert len(response.json()["transactions"]) == 1


def test_transactions_search_treats_percent_and_underscore_as_literal() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-PERCENT",
                    description="TEST MERCHANT 50% OFF",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-OTHER",
                    description="TEST MERCHANT FULL PRICE",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"q": "50%"})

    # "%" is a literal here, not a wildcard — only the row that actually
    # contains "50%" matches, not every row (which an unescaped LIKE would).
    assert response.status_code == 200
    assert [t["description"] for t in response.json()["transactions"]] == [
        "TEST MERCHANT 50% OFF"
    ]


def test_transactions_blank_search_term_is_ignored() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add(
            _tx(
                user_id=dev_user_id,
                account_id=account_id,
                stable_key="TX-ANY",
                description="TEST MERCHANT ANY",
                booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                value_date=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()

    response = _client(engine).get("/transactions", params={"q": "   "})

    assert response.status_code == 200
    assert len(response.json()["transactions"]) == 1


def test_transactions_search_combines_with_account_filter() -> None:
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
                    description="TEST MERCHANT SHARED",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_b,
                    stable_key="TX-B",
                    description="TEST MERCHANT SHARED",
                    booked_at=datetime(2026, 1, 2, tzinfo=UTC),
                    value_date=datetime(2026, 1, 2, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get(
        "/transactions", params={"q": "shared", "account_id": str(account_a)}
    )

    assert response.status_code == 200
    assert len(response.json()["transactions"]) == 1


def test_transactions_rejects_search_term_too_long() -> None:
    response = _client(_sqlite_engine()).get("/transactions", params={"q": "x" * 101})

    assert response.status_code == 422
    assert response.json()["detail"] == "search_too_long"


# --- GET /transactions?start=&end= -------------------------------------------


def test_transactions_period_filter_is_half_open() -> None:
    dev_user_id = get_settings().dev_user_id
    account_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-JAN",
                    description="TEST MERCHANT JAN",
                    booked_at=datetime(2026, 1, 1, tzinfo=UTC),
                    value_date=datetime(2026, 1, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-FEB-BOUNDARY",
                    description="TEST MERCHANT FEB BOUNDARY",
                    booked_at=datetime(2026, 2, 1, tzinfo=UTC),
                    value_date=datetime(2026, 2, 1, tzinfo=UTC),
                ),
                _tx(
                    user_id=dev_user_id,
                    account_id=account_id,
                    stable_key="TX-JAN-15",
                    description="TEST MERCHANT JAN 15",
                    booked_at=datetime(2026, 1, 15, tzinfo=UTC),
                    value_date=datetime(2026, 1, 15, tzinfo=UTC),
                ),
            ]
        )
        session.commit()

    response = _client(engine).get(
        "/transactions",
        params={
            "start": datetime(2026, 1, 1, tzinfo=UTC).isoformat(),
            "end": datetime(2026, 2, 1, tzinfo=UTC).isoformat(),
        },
    )

    assert response.status_code == 200
    # start is inclusive, end is exclusive: the row exactly on `end` is out.
    assert [t["description"] for t in response.json()["transactions"]] == [
        "TEST MERCHANT JAN 15",
        "TEST MERCHANT JAN",
    ]


# --- GET /transactions/{transaction_id} --------------------------------------


def test_get_transaction_returns_the_callers_transaction() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(
            user_id=dev_user_id,
            account_id=uuid4(),
            stable_key="TX-A",
            description="TEST MERCHANT 01",
            booked_at=datetime(2026, 1, 1, tzinfo=UTC),
            value_date=datetime(2026, 1, 1, tzinfo=UTC),
        )
        session.add(tx)
        session.commit()
        tx_id = tx.id

    response = _client(engine).get(f"/transactions/{tx_id}")

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(tx_id)
    assert body["amount"] == -1234
    assert body["effective_amount"] == -1234


def test_get_transaction_exposes_event_id() -> None:
    dev_user_id = get_settings().dev_user_id
    event_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(
            user_id=dev_user_id,
            account_id=uuid4(),
            stable_key="TX-A",
            description="TEST MERCHANT 01",
            booked_at=datetime(2026, 1, 1, tzinfo=UTC),
            value_date=datetime(2026, 1, 1, tzinfo=UTC),
            event_id=event_id,
        )
        session.add(tx)
        session.commit()
        tx_id = tx.id

    response = _client(engine).get(f"/transactions/{tx_id}")

    assert response.status_code == 200
    assert response.json()["event_id"] == str(event_id)


def test_get_transaction_404_for_unknown_id() -> None:
    response = _client(_sqlite_engine()).get(f"/transactions/{uuid4()}")

    assert response.status_code == 404


def test_get_transaction_404_for_another_users_transaction() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(
            user_id=stranger_id,
            account_id=uuid4(),
            stable_key="TX-STRANGER",
            description="STRANGER MERCHANT",
            booked_at=datetime(2026, 1, 1, tzinfo=UTC),
            value_date=datetime(2026, 1, 1, tzinfo=UTC),
        )
        session.add(tx)
        session.commit()
        tx_id = tx.id

    response = _client(engine).get(f"/transactions/{tx_id}")

    assert response.status_code == 404


def test_get_transaction_matches_list_endpoints_effective_amount_for_an_advance() -> None:
    """The single-row endpoint duplicates the list endpoint's advance-share
    resolution (`spending_shares`) — this pins both call sites to agree."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(
            user_id=dev_user_id,
            account_id=uuid4(),
            stable_key="TX-ADVANCE",
            description="TEST MERCHANT ADVANCE",
            booked_at=datetime(2026, 1, 1, tzinfo=UTC),
            value_date=datetime(2026, 1, 1, tzinfo=UTC),
        )
        tx.amount = -5000
        session.add(tx)
        session.commit()
        tx_id = tx.id

    client = _client(engine)
    advance_response = client.post(
        "/advances",
        json={
            "transaction_id": str(tx_id),
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    )
    assert advance_response.status_code == 201

    list_row = next(
        t for t in client.get("/transactions").json()["transactions"] if t["id"] == str(tx_id)
    )
    single_row = client.get(f"/transactions/{tx_id}").json()

    assert single_row["effective_amount"] == list_row["effective_amount"] == -1000


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
