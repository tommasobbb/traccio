"""End-to-end tests for manual accounts and manual transaction CRUD (ADR 0020).

The app is built via the factory with ``get_session`` overridden to a shared
in-memory SQLite engine, so routing, schemas, and repository queries are all
exercised without a running PostgreSQL. Values are synthetic
(``.claude/rules/data-safety.md``): invented names, round amounts.
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.models import AccountRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind, KeyStrategy, TransactionStatus


def _client(engine: Engine) -> TestClient:
    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    return TestClient(app)


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine


def _seed_synced_account(
    engine: Engine, user_id: UUID, *, identification_hash: str = "h-synced-1"
) -> UUID:
    """Insert a bank-backed account row and return its id."""
    account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=account_id,
                user_id=user_id,
                connection_id=uuid4(),
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash=identification_hash,
                name="TEST CURRENT 01",
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()
    return account_id


def _seed_manual_account_row(engine: Engine, user_id: UUID) -> UUID:
    """Insert a manual account row directly (bypassing the endpoint) and return its id."""
    account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=account_id,
                user_id=user_id,
                connection_id=None,
                kind=AccountKind.CASH,
                currency="EUR",
                identification_hash=None,
                name=None,
                alias="Contanti",
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()
    return account_id


def _create_manual_account(client: TestClient, *, alias: str = "Contanti") -> dict:
    response = client.post("/accounts", json={"alias": alias, "kind": "cash", "currency": "EUR"})
    assert response.status_code == 201, response.text
    return response.json()


def _create_manual_tx(
    client: TestClient, account_id: str, *, amount: int = -1500, description: str = "TEST CASH 01"
) -> dict:
    response = client.post(
        "/transactions",
        json={
            "account_id": account_id,
            "amount": amount,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": description,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


# --- creating a manual account -------------------------------------------------


def test_create_manual_account_has_no_connection_and_manual_source() -> None:
    body = _create_manual_account(_client(_engine()), alias="  Contanti  ")

    assert body["connection_id"] is None
    assert body["source"] == "manual"
    assert body["kind"] == "cash"
    assert body["alias"] == "Contanti"
    assert body["display_name"] == "Contanti"
    assert body["name"] is None


def test_create_manual_account_rejects_blank_alias() -> None:
    response = _client(_engine()).post(
        "/accounts", json={"alias": "   ", "kind": "cash", "currency": "EUR"}
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "blank_alias"


def test_created_manual_account_is_listed() -> None:
    client = _client(_engine())
    _create_manual_account(client)

    listed = client.get("/accounts").json()["accounts"]
    assert [a["source"] for a in listed] == ["manual"]


# --- deleting a manual account ----------------------------------------------


def test_delete_manual_account_removes_it() -> None:
    engine = _engine()
    client = _client(engine)
    account_id = _create_manual_account(client)["id"]

    response = client.delete(f"/accounts/{account_id}")

    assert response.status_code == 204
    with Session(engine) as session:
        assert session.scalars(select(AccountRow)).all() == []


def test_delete_synced_account_is_refused() -> None:
    engine = _engine()
    account_id = _seed_synced_account(engine, get_settings().dev_user_id)

    response = _client(engine).delete(f"/accounts/{account_id}")

    assert response.status_code == 409
    assert response.json()["detail"] == "account_not_manual"


def test_delete_manual_account_with_transactions_is_refused() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    _create_manual_tx(client, account_id)

    response = client.delete(f"/accounts/{account_id}")

    assert response.status_code == 409
    assert response.json()["detail"] == "account_not_empty"


def test_delete_manual_account_succeeds_once_emptied() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    tx_id = _create_manual_tx(client, account_id)["id"]

    assert client.delete(f"/transactions/{tx_id}").status_code == 204
    assert client.delete(f"/accounts/{account_id}").status_code == 204


def test_delete_another_users_account_is_404() -> None:
    engine = _engine()
    stranger_account_id = _seed_manual_account_row(engine, uuid4())

    response = _client(engine).delete(f"/accounts/{stranger_account_id}")

    assert response.status_code == 404


# --- creating a manual transaction ----------------------------------------


def test_create_manual_transaction_is_booked_personal_and_manual_keyed() -> None:
    engine = _engine()
    client = _client(engine)
    account_id = _create_manual_account(client)["id"]

    body = _create_manual_tx(client, account_id, amount=-1500)

    assert body["status"] == "booked"
    assert body["role"] == "personal"
    assert body["amount"] == -1500
    assert body["effective_amount"] == -1500
    assert body["booked_at"] is None
    with Session(engine) as session:
        row = session.scalars(select(TransactionRow)).one()
        assert row.key_strategy is KeyStrategy.MANUAL
        assert row.stable_key == str(row.id)
        assert row.last_synced_at is None


def test_create_manual_transaction_on_synced_account_is_refused() -> None:
    engine = _engine()
    account_id = _seed_synced_account(engine, get_settings().dev_user_id)

    response = _client(engine).post(
        "/transactions",
        json={
            "account_id": str(account_id),
            "amount": -100,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": "TEST 01",
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "account_not_manual"


def test_create_manual_transaction_unknown_account_is_404() -> None:
    response = _client(_engine()).post(
        "/transactions",
        json={
            "account_id": str(uuid4()),
            "amount": -100,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": "TEST 01",
        },
    )

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown account"


def test_create_manual_transaction_unknown_category_is_404() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]

    response = client.post(
        "/transactions",
        json={
            "account_id": account_id,
            "amount": -100,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": "TEST 01",
            "confirmed_category_id": str(uuid4()),
        },
    )

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown category"


def test_create_manual_transaction_with_category_confirms_it() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    category_id = client.post("/categories", json={"name": "Snacks"}).json()["id"]

    body = client.post(
        "/transactions",
        json={
            "account_id": account_id,
            "amount": -300,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": "TEST CASH 02",
            "confirmed_category_id": category_id,
        },
    ).json()

    assert body["confirmed_category_id"] == category_id
    assert body["effective_category_id"] == category_id


def test_manual_transaction_rejects_float_amount() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]

    response = client.post(
        "/transactions",
        json={
            "account_id": account_id,
            "amount": 12.34,
            "currency": "EUR",
            "value_date": "2026-08-20T10:00:00Z",
            "description": "TEST 01",
        },
    )

    assert response.status_code == 422


# --- editing a manual transaction ---------------------------------------------


def test_edit_manual_transaction_changes_movement_fields() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    tx_id = _create_manual_tx(client, account_id, amount=-1500)["id"]

    response = client.post(
        f"/transactions/{tx_id}/edit",
        json={
            "amount": -2000,
            "currency": "EUR",
            "value_date": "2026-08-21T09:00:00Z",
            "description": "TEST CASH 01 (fixed)",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["amount"] == -2000
    assert body["description"] == "TEST CASH 01 (fixed)"
    assert body["id"] == tx_id  # identity is stable across an edit


def test_edit_synced_transaction_is_refused() -> None:
    engine = _engine()
    dev_user_id = get_settings().dev_user_id
    account_id = _seed_synced_account(engine, dev_user_id)
    tx_id = uuid4()
    with Session(engine) as session:
        session.add(
            TransactionRow(
                id=tx_id,
                user_id=dev_user_id,
                account_id=account_id,
                amount=-999,
                currency="EUR",
                booked_at=datetime(2026, 8, 1, tzinfo=UTC),
                value_date=datetime(2026, 8, 1, tzinfo=UTC),
                description="TEST SYNCED 01",
                status=TransactionStatus.BOOKED,
                stable_key="TX-synced-1",
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
            )
        )
        session.commit()

    response = _client(engine).post(
        f"/transactions/{tx_id}/edit",
        json={
            "amount": -1,
            "currency": "EUR",
            "value_date": "2026-08-21T09:00:00Z",
            "description": "tampered",
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "transaction_not_manual"


# --- deleting a manual transaction ------------------------------------------


def test_delete_manual_transaction_removes_it() -> None:
    engine = _engine()
    client = _client(engine)
    account_id = _create_manual_account(client)["id"]
    tx_id = _create_manual_tx(client, account_id)["id"]

    assert client.delete(f"/transactions/{tx_id}").status_code == 204
    with Session(engine) as session:
        assert session.scalars(select(TransactionRow)).all() == []


def test_delete_transaction_that_is_an_advance_leg_is_refused() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    tx_id = _create_manual_tx(client, account_id, amount=-5000)["id"]

    advance = client.post(
        "/advances", json={"transaction_id": tx_id, "own_share": 2000, "participants": []}
    )
    assert advance.status_code == 201, advance.text

    response = client.delete(f"/transactions/{tx_id}")

    assert response.status_code == 409
    assert response.json()["detail"] == "transaction_in_use"


def test_delete_unknown_transaction_is_404() -> None:
    response = _client(_engine()).delete(f"/transactions/{uuid4()}")
    assert response.status_code == 404


# --- interaction with other read paths ------------------------------------


def test_manual_expense_contributes_full_amount_to_dashboard() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    _create_manual_tx(client, account_id, amount=-1500)
    _create_manual_tx(client, account_id, amount=4200, description="TEST CASH IN 01")

    summary = client.get(
        "/dashboard/summary",
        params={"start": "2026-08-01T00:00:00Z", "end": "2026-09-01T00:00:00Z"},
    ).json()

    eur = next(c for c in summary["currencies"] if c["currency"] == "EUR")
    assert eur["spending"] == 1500
    assert eur["income"] == 4200


def test_manual_transaction_survives_prune_pending() -> None:
    client = _client(_engine())
    account_id = _create_manual_account(client)["id"]
    _create_manual_tx(client, account_id)

    response = client.post("/transactions/prune-pending")

    assert response.status_code == 200
    assert response.json()["pruned"] == 0
    assert len(client.get("/transactions").json()["transactions"]) == 1


def test_stranger_cannot_delete_a_manual_account_via_scoping() -> None:
    """A manual account created for the dev user is invisible to any other id.

    ``current_user_id`` is fixed to the dev user in tests, so the direct
    check is that a random account id 404s — the same cross-user gate every
    other endpoint relies on (``get_account`` is ``user_id``-scoped).
    """
    client = _client(_engine())
    _create_manual_account(client)

    assert client.delete(f"/accounts/{uuid4()}").status_code == 404
