"""Tests for ``GET /accounts``.

The app is built via the factory and its ``get_session`` dependency is
overridden to a shared in-memory SQLite engine, so the endpoint is exercised
end to end (routing, response schema, repository query) without a running
PostgreSQL. Values are synthetic (see ``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine, select
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _sqlite_engine
from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.models import AccountRow
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind


def _account(
    user_id: UUID, identification_hash: str, name: str, created_at: datetime
) -> AccountRow:
    """Build a synthetic account row for ``user_id``."""
    return AccountRow(
        id=uuid4(),
        user_id=user_id,
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
        name=name,
        created_at=created_at,
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


def test_accounts_returns_only_current_users_accounts_oldest_first() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        session.add_all(
            [
                _account(dev_user_id, "h-2", "TEST B", datetime(2026, 2, 1, tzinfo=UTC)),
                _account(dev_user_id, "h-1", "TEST A", datetime(2026, 1, 1, tzinfo=UTC)),
                _account(stranger_id, "h-x", "STRANGER", datetime(2026, 1, 1, tzinfo=UTC)),
            ]
        )
        session.commit()

    response = _client(engine).get("/accounts")

    assert response.status_code == 200
    accounts = response.json()["accounts"]
    # Only the dev user's accounts, oldest first; the stranger's is excluded.
    assert [a["name"] for a in accounts] == ["TEST A", "TEST B"]


def test_accounts_empty_when_user_has_none() -> None:
    response = _client(_sqlite_engine()).get("/accounts")

    assert response.status_code == 200
    assert response.json() == {"accounts": []}


def _seed_one_account(engine: Engine, *, user_id: UUID, name: str = "TEST CURRENT 01") -> UUID:
    """Insert one account row for ``user_id`` and return its id."""
    with Session(engine) as session:
        session.add(_account(user_id, "h-1", name, datetime(2026, 1, 1, tzinfo=UTC)))
        session.commit()
    with Session(engine) as session:
        row = session.scalars(select(AccountRow).where(AccountRow.user_id == user_id)).one()
        return row.id


def test_rename_account_sets_alias_and_resolves_display_name() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id, name="TEST CURRENT 01")

    response = _client(engine).post(
        f"/accounts/{account_id}/rename", json={"alias": "  My salary account  "}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["alias"] == "My salary account"
    assert body["name"] == "TEST CURRENT 01"
    assert body["display_name"] == "My salary account"


def test_rename_account_with_null_alias_clears_it() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id, name="TEST CURRENT 01")
    client = _client(engine)
    client.post(f"/accounts/{account_id}/rename", json={"alias": "Temporary alias"})

    response = client.post(f"/accounts/{account_id}/rename", json={"alias": None})

    assert response.status_code == 200
    body = response.json()
    assert body["alias"] is None
    assert body["display_name"] == "TEST CURRENT 01"


def test_rename_account_rejects_blank_alias() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id)

    response = _client(engine).post(f"/accounts/{account_id}/rename", json={"alias": "   "})

    assert response.status_code == 422
    assert response.json()["detail"] == "blank_alias"


def test_rename_account_rejects_too_long_alias() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id)

    response = _client(engine).post(f"/accounts/{account_id}/rename", json={"alias": "a" * 256})

    assert response.status_code == 422
    assert response.json()["detail"] == "alias_too_long"


def test_rename_account_404_for_another_users_account() -> None:
    engine = _sqlite_engine()
    stranger_id = uuid4()
    account_id = _seed_one_account(engine, user_id=stranger_id)

    response = _client(engine).post(f"/accounts/{account_id}/rename", json={"alias": "Nice try"})

    assert response.status_code == 404


def test_rename_account_404_for_unknown_account() -> None:
    response = _client(_sqlite_engine()).post(
        f"/accounts/{uuid4()}/rename", json={"alias": "Nice try"}
    )

    assert response.status_code == 404


def test_set_account_appearance() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id)

    response = _client(engine).post(
        f"/accounts/{account_id}/appearance", json={"color": "teal", "icon": "savings"}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["color"] == "teal"
    assert body["icon"] == "savings"


def test_set_account_appearance_rejects_unknown_color() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_one_account(engine, user_id=dev_user_id)

    response = _client(engine).post(
        f"/accounts/{account_id}/appearance", json={"color": "not-a-color", "icon": "bank"}
    )

    assert response.status_code == 422


def test_set_account_appearance_404_for_another_users_account() -> None:
    engine = _sqlite_engine()
    stranger_id = uuid4()
    account_id = _seed_one_account(engine, user_id=stranger_id)

    response = _client(engine).post(
        f"/accounts/{account_id}/appearance", json={"color": "teal", "icon": "bank"}
    )

    assert response.status_code == 404
