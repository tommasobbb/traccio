"""Tests for ``POST /imports/preview`` and ``POST /imports/commit`` (ADR 0023).

The app is built via the factory with ``get_session`` overridden to a shared
in-memory SQLite engine, so the endpoints run end to end (routing, xlsx/csv
decode, parse, insert). Files are built in-memory; values are synthetic
(``.claude/rules/data-safety.md``).
"""

import base64
import csv
import io
from collections.abc import Iterator, Sequence
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from openpyxl import Workbook
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.models import AccountRow
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind

_SATISPAY_HEADER = [
    "Data",
    "Nome",
    "Descrizione",
    "Importo",
    "Tipo",
    "Stato",
    "Disponibilità",
    "Buoni Pasto",
    "Disponibilità dopo la transazione",
    "ID",
]


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


def _sqlite_engine() -> Engine:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine


def _account(engine: Engine, *, user_id: UUID, kind: AccountKind, manual: bool) -> UUID:
    account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=account_id,
                user_id=user_id,
                connection_id=None if manual else uuid4(),
                kind=kind,
                currency="EUR",
                identification_hash=None if manual else f"h-{account_id}",
                name=None if manual else "TEST BANK ACCOUNT 01",
                alias="Satispay" if manual else None,
                created_at=datetime(2026, 1, 1, tzinfo=UTC),
            )
        )
        session.commit()
    return account_id


def _satispay_xlsx(rows: Sequence[Sequence[object]]) -> str:
    workbook = Workbook()
    sheet = workbook.active
    assert sheet is not None
    sheet.append(_SATISPAY_HEADER)
    for row in rows:
        sheet.append(list(row))
    buffer = io.BytesIO()
    workbook.save(buffer)
    return base64.b64encode(buffer.getvalue()).decode()


def _satispay_row(
    *,
    when: str = "25/06/2026 21:56",
    name: str = "TEST MERCHANT 01",
    importo: str = "-42,00",
    stato: str = "✅ Approvato",
    disponibilita: str = "-2,00",
    buoni: str = "-40,00",
    row_id: str = "019f005a-9877-7777-90a3-fa4fdec9e106",
) -> list[object]:
    return [
        when,
        name,
        "",
        importo,
        "🏪 a un Negozio",
        stato,
        disponibilita,
        buoni,
        "€0,00",
        row_id,
    ]


def _generic_csv(rows: Sequence[Sequence[str]]) -> str:
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(["date", "amount", "description"])
    writer.writerows(rows)
    return base64.b64encode(buffer.getvalue().encode()).decode()


def _transactions(client: TestClient) -> list[dict[str, object]]:
    return client.get("/transactions").json()["transactions"]


def test_preview_classifies_a_split_row_and_a_balance_only_row() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    voucher = _account(engine, user_id=user_id, kind=AccountKind.CASH, manual=True)
    content = _satispay_xlsx(
        [
            _satispay_row(),  # mixed: -2,00 + -40,00
            _satispay_row(
                row_id="019edb48-4e95-700a-b0db-7fc92723e143",
                importo="-9,00",
                disponibilita="-9,00",
                buoni="",
            ),
        ]
    )

    response = _client(engine).post(
        "/imports/preview",
        json={
            "account_id": str(primary),
            "voucher_account_id": str(voucher),
            "profile": "satispay",
            "filename": "satispay-june.xlsx",
            "content_base64": content,
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["summary"] == {"new": 3, "already_imported": 0, "invalid": 0, "total": 3}
    by_target: dict[str, list[int]] = {}
    for row in body["rows"]:
        assert row["status"] == "new"
        by_target.setdefault(row["target_account_id"], []).append(row["amount"])
    assert sorted(by_target[str(primary)]) == [-900, -200]
    assert by_target[str(voucher)] == [-4000]


def test_commit_inserts_new_rows_and_a_second_commit_adds_nothing() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    voucher = _account(engine, user_id=user_id, kind=AccountKind.CASH, manual=True)
    content = _satispay_xlsx([_satispay_row()])
    client = _client(engine)
    payload = {
        "account_id": str(primary),
        "voucher_account_id": str(voucher),
        "profile": "satispay",
        "filename": "s.xlsx",
        "content_base64": content,
    }

    first = client.post("/imports/commit", json=payload)
    assert first.status_code == 201
    assert first.json() == {"imported": 2, "skipped": 0, "invalid": 0}
    assert len(_transactions(client)) == 2

    second = client.post("/imports/commit", json=payload)
    assert second.status_code == 201
    assert second.json() == {"imported": 0, "skipped": 2, "invalid": 0}
    assert len(_transactions(client)) == 2


def test_preview_marks_rows_already_imported_after_a_commit() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    voucher = _account(engine, user_id=user_id, kind=AccountKind.CASH, manual=True)
    content = _satispay_xlsx([_satispay_row()])
    client = _client(engine)
    payload = {
        "account_id": str(primary),
        "voucher_account_id": str(voucher),
        "profile": "satispay",
        "filename": "s.xlsx",
        "content_base64": content,
    }
    client.post("/imports/commit", json=payload)

    body = client.post("/imports/preview", json=payload).json()

    assert body["summary"] == {"new": 0, "already_imported": 2, "invalid": 0, "total": 2}


def test_voucher_account_required_when_the_file_has_voucher_amounts() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    content = _satispay_xlsx([_satispay_row()])

    response = _client(engine).post(
        "/imports/preview",
        json={
            "account_id": str(primary),
            "profile": "satispay",
            "filename": "s.xlsx",
            "content_base64": content,
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "voucher_account_required"


def test_a_synced_primary_account_is_refused() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    synced = _account(engine, user_id=user_id, kind=AccountKind.CURRENT, manual=False)
    content = _satispay_xlsx([_satispay_row(importo="-1,00", disponibilita="-1,00", buoni="")])

    response = _client(engine).post(
        "/imports/preview",
        json={
            "account_id": str(synced),
            "profile": "satispay",
            "filename": "s.xlsx",
            "content_base64": content,
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "account_not_manual"


def test_missing_columns_is_422() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    # A generic CSV fed to the satispay profile: none of its headers match.
    content = _generic_csv([["2026-03-01", "-12.34", "TEST MERCHANT 01"]])

    response = _client(engine).post(
        "/imports/preview",
        json={
            "account_id": str(primary),
            "profile": "satispay",
            "filename": "wrong.csv",
            "content_base64": content,
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "missing_columns"


def test_a_file_over_the_size_limit_is_413() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    oversized = base64.b64encode(b"x" * (get_settings().import_max_bytes + 1)).decode()

    response = _client(engine).post(
        "/imports/preview",
        json={
            "account_id": str(primary),
            "profile": "satispay",
            "filename": "big.xlsx",
            "content_base64": oversized,
        },
    )

    assert response.status_code == 413
    assert response.json()["detail"] == "file_too_large"


def test_generic_csv_import_round_trips() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.CASH, manual=True)
    content = _generic_csv(
        [
            ["2026-03-01", "-12.34", "TEST MERCHANT 01"],
            ["2026-03-02", "45.00", "TEST REFUND 01"],
        ]
    )
    client = _client(engine)
    payload = {
        "account_id": str(primary),
        "profile": "generic",
        "filename": "ledger.csv",
        "content_base64": content,
    }

    assert client.post("/imports/commit", json=payload).json() == {
        "imported": 2,
        "skipped": 0,
        "invalid": 0,
    }
    amounts = sorted(t["amount"] for t in _transactions(client))
    assert amounts == [-1234, 4500]


def test_an_invalid_row_is_reported_and_not_imported() -> None:
    user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    primary = _account(engine, user_id=user_id, kind=AccountKind.WALLET, manual=True)
    voucher = _account(engine, user_id=user_id, kind=AccountKind.CASH, manual=True)
    content = _satispay_xlsx(
        [
            _satispay_row(importo="-1,00", disponibilita="-1,00", buoni=""),
            _satispay_row(row_id="019ec69a-a9f6-7588-b703-c22d4491348a", stato="❌ Rifiutato"),
        ]
    )
    client = _client(engine)
    payload = {
        "account_id": str(primary),
        "voucher_account_id": str(voucher),
        "profile": "satispay",
        "filename": "s.xlsx",
        "content_base64": content,
    }

    preview = client.post("/imports/preview", json=payload).json()
    assert preview["summary"] == {"new": 1, "already_imported": 0, "invalid": 1, "total": 2}
    [invalid] = [r for r in preview["rows"] if r["status"] == "invalid"]
    assert invalid["reason"] == "unknown_status"
    assert invalid["row_number"] == 2

    assert client.post("/imports/commit", json=payload).json() == {
        "imported": 1,
        "skipped": 0,
        "invalid": 1,
    }
