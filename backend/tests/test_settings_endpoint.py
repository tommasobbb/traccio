"""Tests for the per-user settings endpoints (ADR 0024).

The app is built via the factory with ``get_session`` overridden to a shared
in-memory SQLite engine. A fresh test database has no ``users`` row for the
dev user — ``GET /settings`` must tolerate that and ``POST /settings`` must
insert one. Values are synthetic (``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _sqlite_engine
from traccio.api.main import create_app
from traccio.core.config import get_settings
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


def _account(engine: Engine, *, user_id: UUID, alias: str) -> UUID:
    account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=account_id,
                user_id=user_id,
                connection_id=uuid4(),
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash=f"h-{account_id}",
                name="Provider Account",
                alias=alias,
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()
    return account_id


def _tx(engine: Engine, *, user_id: UUID, account_id: UUID, when: datetime, key: str) -> None:
    with Session(engine) as session:
        session.add(
            TransactionRow(
                id=uuid4(),
                user_id=user_id,
                account_id=account_id,
                amount=-1000,
                currency="EUR",
                booked_at=when,
                value_date=when,
                description="TEST MERCHANT 01",
                display_description=None,
                status=TransactionStatus.BOOKED,
                entry_reference=key,
                stable_key=key,
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
            )
        )
        session.commit()


def test_get_settings_is_null_before_anything_is_set() -> None:
    response = _client(_sqlite_engine()).get("/settings")
    assert response.status_code == 200
    assert response.json() == {"tracking_start_date": None, "meal_vouchers_enabled": False}


def test_set_then_get_round_trips_and_a_null_clears_it() -> None:
    client = _client(_sqlite_engine())

    set_response = client.post("/settings", json={"tracking_start_date": "2026-07-01"})
    assert set_response.status_code == 200
    assert set_response.json() == {
        "tracking_start_date": "2026-07-01",
        "meal_vouchers_enabled": False,
    }
    assert client.get("/settings").json() == {
        "tracking_start_date": "2026-07-01",
        "meal_vouchers_enabled": False,
    }

    clear_response = client.post("/settings", json={"tracking_start_date": None})
    assert clear_response.status_code == 200
    assert clear_response.json() == {"tracking_start_date": None, "meal_vouchers_enabled": False}
    assert client.get("/settings").json() == {
        "tracking_start_date": None,
        "meal_vouchers_enabled": False,
    }


def test_set_requires_the_key_to_be_present() -> None:
    # Mandatory-but-nullable: an empty body is a 422, not "leave it alone".
    response = _client(_sqlite_engine()).post("/settings", json={})
    assert response.status_code == 422


def test_meal_vouchers_is_off_before_anything_is_set() -> None:
    response = _client(_sqlite_engine()).get("/settings")
    assert response.status_code == 200
    assert response.json()["meal_vouchers_enabled"] is False


def test_set_meal_vouchers_round_trips_and_a_second_call_reverses_it() -> None:
    """Reversible (ADR 0029): turning it on, then off again, returns exactly
    to the starting state — no other setting is disturbed either way."""
    client = _client(_sqlite_engine())
    client.post("/settings", json={"tracking_start_date": "2026-07-01"})

    on_response = client.post("/settings/meal-vouchers", json={"enabled": True})
    assert on_response.status_code == 200
    assert on_response.json() == {
        "tracking_start_date": "2026-07-01",
        "meal_vouchers_enabled": True,
    }
    assert client.get("/settings").json()["meal_vouchers_enabled"] is True

    off_response = client.post("/settings/meal-vouchers", json={"enabled": False})
    assert off_response.status_code == 200
    assert off_response.json() == {
        "tracking_start_date": "2026-07-01",
        "meal_vouchers_enabled": False,
    }


def test_suggestion_is_the_month_after_the_latest_starting_account() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    early = _account(engine, user_id=user_id, alias="Revolut")
    late = _account(engine, user_id=user_id, alias="Satispay")
    empty = _account(engine, user_id=user_id, alias="Contanti")
    _tx(engine, user_id=user_id, account_id=early, when=datetime(2026, 3, 1, tzinfo=UTC), key="A")
    _tx(engine, user_id=user_id, account_id=late, when=datetime(2026, 6, 15, tzinfo=UTC), key="B")

    body = _client(engine).get("/settings/tracking-start/suggestion").json()

    assert body["suggestion"] == "2026-07-01"
    assert body["constraining_account_id"] == str(late)
    by_id = {row["account_id"]: row for row in body["accounts"]}
    assert by_id[str(early)]["earliest"] == "2026-03-01"
    assert by_id[str(late)]["earliest"] == "2026-06-15"
    # An account with no movements is listed, with a null date, and never
    # constrains the suggestion.
    assert by_id[str(empty)]["earliest"] is None
    # Sort order: earliest-movement first, no-movement account last.
    assert [row["account_id"] for row in body["accounts"]] == [str(early), str(late), str(empty)]


def test_suggestion_is_null_when_no_account_has_a_dated_movement() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _account(engine, user_id=user_id, alias="Contanti")

    body = _client(engine).get("/settings/tracking-start/suggestion").json()

    assert body["suggestion"] is None
    assert body["constraining_account_id"] is None
