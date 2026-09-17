"""Tests for ``GET /dashboard/summary``.

The app is built via the factory and its ``get_session`` dependency is
overridden to a shared in-memory SQLite engine, so the endpoint is exercised
end to end (routing, response schema, repository query, advance share
resolution) without a running PostgreSQL. Values are synthetic (see
``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.models import AccountRow, CategoryRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind, KeyStrategy, PaletteColor, TransactionStatus

_IN_PERIOD = datetime(2026, 8, 15, tzinfo=UTC)
_BEFORE_PERIOD = datetime(2026, 7, 1, tzinfo=UTC)


def _tx(
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    booked_at: datetime = _IN_PERIOD,
    confirmed_category_id: UUID | None = None,
    account_id: UUID | None = None,
    currency: str = "EUR",
) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=account_id or uuid4(),
        amount=amount,
        currency=currency,
        booked_at=booked_at,
        value_date=booked_at,
        description="TEST MERCHANT 01",
        display_description=None,
        status=TransactionStatus.BOOKED,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        confirmed_category_id=confirmed_category_id,
    )


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
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _seed_tx(
    engine: Engine,
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    booked_at: datetime = _IN_PERIOD,
    confirmed_category_id: UUID | None = None,
    account_id: UUID | None = None,
    currency: str = "EUR",
) -> str:
    with Session(engine) as session:
        tx = _tx(
            user_id=user_id,
            amount=amount,
            stable_key=stable_key,
            booked_at=booked_at,
            confirmed_category_id=confirmed_category_id,
            account_id=account_id,
            currency=currency,
        )
        session.add(tx)
        session.commit()
        return str(tx.id)


def _seed_category(
    engine: Engine, *, user_id: UUID, name: str, parent_id: UUID | None = None
) -> str:
    with Session(engine) as session:
        category = CategoryRow(
            id=uuid4(),
            user_id=user_id,
            name=name,
            parent_id=parent_id,
            color=PaletteColor.SLATE,
            created_at=_IN_PERIOD,
        )
        session.add(category)
        session.commit()
        return str(category.id)


def _seed_account(
    engine: Engine,
    *,
    user_id: UUID,
    alias: str | None = None,
    kind: AccountKind = AccountKind.CURRENT,
) -> str:
    with Session(engine) as session:
        account = AccountRow(
            id=uuid4(),
            user_id=user_id,
            connection_id=uuid4(),
            kind=kind,
            currency="EUR",
            identification_hash=f"HASH-{uuid4()}",
            name="Provider Account",
            alias=alias,
            created_at=_IN_PERIOD,
        )
        session.add(account)
        session.commit()
        return str(account.id)


def test_summary_with_only_personal_transactions() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="SPEND")
    _seed_tx(engine, user_id=dev_user_id, amount=2000, stable_key="INCOME")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["currency"] == "EUR"
    assert summary["spending"] == 5000
    assert summary["income"] == 2000
    assert summary["net"] == -3000
    assert summary["transaction_count"] == 2
    assert summary["comparison"] is None
    assert summary["by_category"] == [
        {
            "category_id": None,
            "category_name": None,
            "color": None,
            "icon": None,
            "spending": 5000,
            "income": 2000,
            "transaction_count": 2,
            "direct_spending": 5000,
            "direct_income": 2000,
            "direct_transaction_count": 2,
            "children": [],
        }
    ]
    assert summary["by_bucket"] == [
        {
            "start": "2026-08-15",
            "end": "2026-08-16",
            "spending": 5000,
            "income": 2000,
            "transaction_count": 2,
        }
    ]


def test_summary_shows_advance_share_not_full_amount() -> None:
    """This is the roadmap's M2 'done when': tag a real advance and see the
    dashboard show the actual share, not the full amount."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-100000, stable_key="TRIP")  # €1000
    client = _client(engine)
    advance_response = client.post(
        "/advances", json={"transaction_id": tx_id, "own_share": 20000, "participants": []}
    )
    assert advance_response.status_code == 201

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 20000
    assert summary["transaction_count"] == 1


def test_summary_excludes_a_confirmed_transfer() -> None:
    """A transfer between own accounts is not spending — see ADR 0007."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="OUT")
    in_id = _seed_tx(engine, user_id=dev_user_id, amount=5000, stable_key="IN")
    _seed_tx(engine, user_id=dev_user_id, amount=-1200, stable_key="PERSONAL")
    client = _client(engine)
    confirm = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )
    assert confirm.status_code == 201

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    # Only the untouched personal spend counts; the confirmed transfer pair
    # contributes zero to both spending and income.
    assert summary["spending"] == 1200
    assert summary["income"] == 0
    assert summary["transaction_count"] == 3


def test_summary_counts_a_funded_payment_once() -> None:
    """A card-funded wallet payment (``TransferKind.FUNDED_PAYMENT``) must not
    double-count: the funding leg is zeroed, the wallet leg is the real spend."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    bank_id = _seed_account(engine, user_id=dev_user_id, kind=AccountKind.CURRENT)
    wallet_id = _seed_account(engine, user_id=dev_user_id, kind=AccountKind.WALLET)
    funding_id = _seed_tx(
        engine, user_id=dev_user_id, amount=-1290, stable_key="CARD", account_id=UUID(bank_id)
    )
    funded_id = _seed_tx(
        engine, user_id=dev_user_id, amount=-1290, stable_key="WALLET", account_id=UUID(wallet_id)
    )
    client = _client(engine)
    confirm = client.post(
        "/transfers/confirm",
        json={
            "kind": "funded_payment",
            "outgoing_transaction_id": funding_id,
            "incoming_transaction_id": funded_id,
        },
    )
    assert confirm.status_code == 201

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    # 12.90 once, not 25.80: only the funded (wallet) leg counts.
    assert summary["spending"] == 1290
    assert summary["income"] == 0
    assert summary["transaction_count"] == 2


def test_summary_filters_by_period() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="OLD", booked_at=_BEFORE_PERIOD)
    _seed_tx(engine, user_id=dev_user_id, amount=-3000, stable_key="NEW", booked_at=_IN_PERIOD)
    client = _client(engine)

    response = client.get(
        "/dashboard/summary",
        params={"start": "2026-08-01T00:00:00Z", "end": "2026-09-01T00:00:00Z"},
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 3000
    assert summary["transaction_count"] == 1


def test_summary_with_no_transactions_returns_no_currencies() -> None:
    engine = _sqlite_engine()
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json() == {
        "currencies": [],
        "converted": None,
        "conversion_unavailable": None,
        "meal_vouchers": [],
    }


def test_summary_is_user_scoped() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=stranger_id, amount=-9999, stable_key="STRANGER")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json() == {
        "currencies": [],
        "converted": None,
        "conversion_unavailable": None,
        "meal_vouchers": [],
    }


def test_summary_by_category_resolves_the_category_display() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    groceries_id = _seed_category(engine, user_id=dev_user_id, name="Groceries")
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="GROCERIES",
        confirmed_category_id=UUID(groceries_id),
    )
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    [entry] = summary["by_category"]
    assert entry["category_id"] == groceries_id
    assert entry["category_name"] == "Groceries"
    assert entry["color"] == "slate"
    assert entry["spending"] == 3000
    assert entry["direct_spending"] == 3000
    assert entry["children"] == []


def test_summary_by_category_has_a_null_bucket_for_uncategorized() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    groceries_id = _seed_category(engine, user_id=dev_user_id, name="Groceries")
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="GROCERIES",
        confirmed_category_id=UUID(groceries_id),
    )
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="UNCATEGORIZED")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    by_category_ids = {entry["category_id"] for entry in summary["by_category"]}
    assert None in by_category_ids
    none_entry = next(e for e in summary["by_category"] if e["category_id"] is None)
    assert none_entry["category_name"] is None
    assert none_entry["spending"] == 1000


def test_summary_by_category_rolls_a_child_up_into_its_root() -> None:
    """ADR 0018's two-level hierarchy landing in the dashboard: a transaction
    confirmed on a child appears rolled up under its root, as one of the
    root's `children`, not as a separate top-level entry."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    root_id = _seed_category(engine, user_id=dev_user_id, name="Dining out")
    child_id = _seed_category(engine, user_id=dev_user_id, name="Coffee", parent_id=UUID(root_id))
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-500,
        stable_key="COFFEE",
        confirmed_category_id=UUID(child_id),
    )
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert len(summary["by_category"]) == 1
    [group] = summary["by_category"]
    assert group["category_id"] == root_id
    assert group["category_name"] == "Dining out"
    assert group["spending"] == 500
    assert group["direct_spending"] == 0
    assert group["direct_transaction_count"] == 0
    [child] = group["children"]
    assert child["category_id"] == child_id
    assert child["category_name"] == "Coffee"
    assert child["spending"] == 500


def test_summary_by_bucket_across_multiple_days() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    day_one = datetime(2026, 8, 10, tzinfo=UTC)
    day_two = datetime(2026, 8, 12, tzinfo=UTC)
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="DAY1", booked_at=day_one)
    _seed_tx(engine, user_id=dev_user_id, amount=-2500, stable_key="DAY2A", booked_at=day_two)
    _seed_tx(engine, user_id=dev_user_id, amount=500, stable_key="DAY2B", booked_at=day_two)
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["by_bucket"] == [
        {
            "start": "2026-08-10",
            "end": "2026-08-11",
            "spending": 1000,
            "income": 0,
            "transaction_count": 1,
        },
        {
            "start": "2026-08-12",
            "end": "2026-08-13",
            "spending": 2500,
            "income": 500,
            "transaction_count": 2,
        },
    ]


def test_summary_by_bucket_gap_fills_when_start_and_end_are_both_given() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1000,
        stable_key="DAY1",
        booked_at=datetime(2026, 8, 10, tzinfo=UTC),
    )
    client = _client(engine)

    response = client.get(
        "/dashboard/summary",
        params={"start": "2026-08-10T00:00:00Z", "end": "2026-08-13T00:00:00Z"},
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    starts = [b["start"] for b in summary["by_bucket"]]
    assert starts == ["2026-08-10", "2026-08-11", "2026-08-12"]
    assert summary["by_bucket"][1]["spending"] == 0
    assert summary["by_bucket"][1]["transaction_count"] == 0


def test_summary_by_bucket_excludes_a_row_with_no_date_but_keeps_it_in_totals() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    with Session(engine) as session:
        tx = _tx(user_id=dev_user_id, amount=-4000, stable_key="NO_DATE")
        tx.booked_at = None
        tx.value_date = None
        session.add(tx)
        session.commit()
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 4000
    assert summary["transaction_count"] == 1
    assert summary["by_bucket"] == []


def test_summary_by_account_resolves_the_account_display_name() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    account_id = _seed_account(engine, user_id=dev_user_id, alias="Conto principale")
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1000,
        stable_key="TX",
        account_id=UUID(account_id),
    )
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["by_account"] == [
        {
            "account_id": account_id,
            "account_name": "Conto principale",
            "color": None,
            "icon": None,
            "spending": 1000,
            "income": 0,
            "transaction_count": 1,
        }
    ]


def test_summary_granularity_month_buckets_by_calendar_month() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1000,
        stable_key="TX",
        booked_at=datetime(2026, 8, 27, tzinfo=UTC),
    )
    client = _client(engine)

    response = client.get("/dashboard/summary", params={"granularity": "month"})

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["by_bucket"] == [
        {
            "start": "2026-08-01",
            "end": "2026-09-01",
            "spending": 1000,
            "income": 0,
            "transaction_count": 1,
        }
    ]


def test_summary_rejects_an_unknown_timezone() -> None:
    engine = _sqlite_engine()
    client = _client(engine)

    response = client.get("/dashboard/summary", params={"tz": "Not/AZone"})

    assert response.status_code == 422
    assert response.json()["detail"] == "unknown_timezone"


def test_summary_rejects_an_incomplete_comparison_period() -> None:
    engine = _sqlite_engine()
    client = _client(engine)

    response = client.get("/dashboard/summary", params={"compare_start": "2026-07-01T00:00:00Z"})

    assert response.status_code == 422
    assert response.json()["detail"] == "incomplete_comparison_period"


def test_summary_with_a_comparison_period_attaches_the_delta() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-5000,
        stable_key="AUGUST",
        booked_at=datetime(2026, 8, 10, tzinfo=UTC),
    )
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="JULY",
        booked_at=datetime(2026, 7, 10, tzinfo=UTC),
    )
    client = _client(engine)

    response = client.get(
        "/dashboard/summary",
        params={
            "start": "2026-08-01T00:00:00Z",
            "end": "2026-09-01T00:00:00Z",
            "compare_start": "2026-07-01T00:00:00Z",
            "compare_end": "2026-08-01T00:00:00Z",
        },
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    assert summary["spending"] == 5000
    assert summary["comparison"] == {
        "spending": 3000,
        "income": 0,
        "net": -3000,
        "spending_delta": 2000,
        "spending_delta_pct": pytest.approx(2000 / 3000),
    }


def test_summary_never_resolves_another_users_category_name() -> None:
    """A category id can only ever come from this user's own transactions
    (every query is user_id-scoped), but the name lookup itself must not leak
    another user's category row even if ids collided by coincidence."""
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    _seed_category(engine, user_id=stranger_id, name="Stranger's category")
    _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="PERSONAL")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    names = {entry["category_name"] for entry in summary["by_category"]}
    assert "Stranger's category" not in names


# --- FX conversion (ADR 0021) --------------------------------------------------

import httpx  # noqa: E402

from traccio.api.deps import get_fx_client  # noqa: E402
from traccio.providers.frankfurter import FrankfurterClient  # noqa: E402

# 1 USD = 0.90 EUR on a day at or before the in-period movement date.
_FX_RANGE_BODY = {
    "amount": 1,
    "base": "USD",
    "start_date": "2026-08-08",
    "end_date": "2026-08-27",
    "rates": {"2026-08-14": {"EUR": 0.9}},
}


def _fx_ok_transport() -> httpx.MockTransport:
    def handle(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/latest"):
            return httpx.Response(
                200, json={"base": "USD", "date": "2026-08-14", "rates": {"EUR": 0.9}}
            )
        return httpx.Response(200, json=_FX_RANGE_BODY)

    return httpx.MockTransport(handle)


def _fx_down_transport() -> httpx.MockTransport:
    return httpx.MockTransport(lambda request: httpx.Response(503, text="down"))


def _client_with_fx(engine: Engine, transport: httpx.MockTransport) -> TestClient:
    client = _client(engine)

    def override_fx_client() -> Iterator[FrankfurterClient]:
        fx = FrankfurterClient(base_url="https://fx.example.test", transport=transport)
        try:
            yield fx
        finally:
            fx.close()

    client.app.dependency_overrides[get_fx_client] = override_fx_client
    return client


def test_summary_converts_a_multi_currency_period_when_fx_is_enabled() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="EUR-SPEND")  # -50.00 EUR
    _seed_tx(
        engine, user_id=dev_user_id, amount=-10000, stable_key="USD-SPEND", currency="USD"
    )  # -100.00 USD -> -90.00 EUR

    response = _client_with_fx(engine, _fx_ok_transport()).get("/dashboard/summary")

    assert response.status_code == 200
    body = response.json()
    # The per-currency breakdown is unchanged: one entry each.
    assert {c["currency"] for c in body["currencies"]} == {"EUR", "USD"}
    assert body["conversion_unavailable"] is None
    converted = body["converted"]
    assert converted is not None
    assert converted["summary"]["currency"] == "EUR"
    assert converted["summary"]["spending"] == 5000 + 9000
    assert converted["basis"] == "historical"
    assert converted["rates"] == [
        {"source_currency": "USD", "rate": "0.9", "rate_date": "2026-08-14"}
    ]


def test_a_fetched_rate_survives_into_a_later_request_on_a_down_api() -> None:
    """The fetched-and-cached rate must actually persist across requests.

    build_rate_resolver (services/fx.py) does not commit — the caller owns
    the transaction boundary, the same convention services/sync.py documents
    and follows. Each request here gets its own session via get_session
    (closed, uncommitted work discarded, at the end of the request); if the
    router forgot to commit after calling it, the rate fetched on the first
    request would vanish and the second request — against a down API, cache
    or nothing — would have to withhold the converted total.
    """
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="EUR-SPEND")
    _seed_tx(engine, user_id=dev_user_id, amount=-10000, stable_key="USD-SPEND", currency="USD")

    first = _client_with_fx(engine, _fx_ok_transport()).get("/dashboard/summary")
    assert first.json()["conversion_unavailable"] is None

    second = _client_with_fx(engine, _fx_down_transport()).get("/dashboard/summary")

    body = second.json()
    assert body["conversion_unavailable"] is None
    assert body["converted"] is not None
    assert body["converted"]["summary"]["spending"] == 5000 + 9000


def test_summary_withholds_the_converted_total_when_rates_are_unavailable() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="EUR-SPEND")
    _seed_tx(engine, user_id=dev_user_id, amount=-10000, stable_key="USD-SPEND", currency="USD")

    response = _client_with_fx(engine, _fx_down_transport()).get("/dashboard/summary")

    assert response.status_code == 200
    body = response.json()
    assert body["converted"] is None
    assert body["conversion_unavailable"] == "rates_unavailable"
    # The per-currency breakdown is still complete.
    assert {c["currency"] for c in body["currencies"]} == {"EUR", "USD"}


def test_summary_has_no_converted_total_when_fx_is_disabled() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-10000, stable_key="USD-SPEND", currency="USD")

    # No get_fx_client override -> the real dep yields None (feature off).
    response = _client(engine).get("/dashboard/summary")

    assert response.status_code == 200
    body = response.json()
    assert body["converted"] is None
    assert body["conversion_unavailable"] is None


def test_summary_tracking_start_clamps_totals_and_the_bucket_grid() -> None:
    """A tracking-start floor (ADR 0024) is raised into the requested period
    before anything is fetched or bucketed — so a pre-floor row drops out of
    the totals and the gap-filled grid starts at the floor, not at the
    requested start."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1000,
        stable_key="JUNE",
        booked_at=datetime(2026, 6, 15, tzinfo=UTC),
    )
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-2000,
        stable_key="JULY",
        booked_at=datetime(2026, 7, 2, tzinfo=UTC),
    )
    client = _client(engine)
    assert client.post("/settings", json={"tracking_start_date": "2026-07-01"}).status_code == 200

    response = client.get(
        "/dashboard/summary",
        params={"start": "2026-06-01T00:00:00Z", "end": "2026-07-04T00:00:00Z"},
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    # The June row is excluded entirely.
    assert summary["spending"] == 2000
    assert summary["transaction_count"] == 1
    # The gap-filled grid begins at the floor, not at 2026-06-01.
    assert [b["start"] for b in summary["by_bucket"]] == ["2026-07-01", "2026-07-02", "2026-07-03"]


# --- Meal vouchers (ADR 0029) ------------------------------------------------


def test_summary_counts_a_voucher_account_normally_when_the_setting_is_off() -> None:
    """The default (and reversible) state: a voucher-kind account is just
    another account, in ``spending`` and ``by_account``, with no breakout."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    voucher_account_id = _seed_account(
        engine, user_id=dev_user_id, kind=AccountKind.VOUCHER, alias="Buoni Pasto"
    )
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1200,
        stable_key="MENSA",
        account_id=UUID(voucher_account_id),
    )
    _seed_tx(engine, user_id=dev_user_id, amount=-500, stable_key="CARD")
    client = _client(engine)

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    body = response.json()
    assert body["meal_vouchers"] == []
    [summary] = body["currencies"]
    assert summary["spending"] == 1700
    assert summary["transaction_count"] == 2
    assert voucher_account_id in {row["account_id"] for row in summary["by_account"]}


def test_summary_excludes_and_breaks_out_voucher_spend_when_the_setting_is_on() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    groceries_id = _seed_category(engine, user_id=dev_user_id, name="Groceries")
    voucher_account_id = _seed_account(
        engine, user_id=dev_user_id, kind=AccountKind.VOUCHER, alias="Buoni Pasto"
    )
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1200,
        stable_key="MENSA",
        account_id=UUID(voucher_account_id),
        confirmed_category_id=UUID(groceries_id),
    )
    _seed_tx(engine, user_id=dev_user_id, amount=-500, stable_key="CARD")
    client = _client(engine)
    assert client.post("/settings/meal-vouchers", json={"enabled": True}).status_code == 200

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    body = response.json()
    # The headline total no longer includes the voucher leg.
    [summary] = body["currencies"]
    assert summary["spending"] == 500
    assert summary["transaction_count"] == 1
    assert voucher_account_id not in {row["account_id"] for row in summary["by_account"]}
    # The voucher leg shows up in its own breakout instead.
    [vouchers] = body["meal_vouchers"]
    assert vouchers["currency"] == "EUR"
    assert vouchers["spending"] == 1200
    assert vouchers["transaction_count"] == 1
    [group] = vouchers["by_category"]
    assert group["category_id"] == groceries_id
    assert group["spending"] == 1200


def test_summary_meal_vouchers_is_empty_with_no_voucher_spend() -> None:
    """The setting is on, but there is nothing to report — the user's
    "se sono stati spesi" case."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, amount=-500, stable_key="CARD")
    client = _client(engine)
    assert client.post("/settings/meal-vouchers", json={"enabled": True}).status_code == 200

    response = client.get("/dashboard/summary")

    assert response.status_code == 200
    assert response.json()["meal_vouchers"] == []


def test_summary_meal_vouchers_comparison_also_excludes_the_voucher_leg() -> None:
    """The comparison delta must be filtered the same way as the main period,
    or it would compare an unfiltered past to a filtered present."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    voucher_account_id = _seed_account(engine, user_id=dev_user_id, kind=AccountKind.VOUCHER)
    _seed_tx(
        engine,
        user_id=dev_user_id,
        amount=-1000,
        stable_key="VOUCHER-PAST",
        account_id=UUID(voucher_account_id),
        booked_at=_BEFORE_PERIOD,
    )
    _seed_tx(
        engine, user_id=dev_user_id, amount=-500, stable_key="CARD-PAST", booked_at=_BEFORE_PERIOD
    )
    _seed_tx(engine, user_id=dev_user_id, amount=-700, stable_key="CARD-NOW")
    client = _client(engine)
    assert client.post("/settings/meal-vouchers", json={"enabled": True}).status_code == 200

    response = client.get(
        "/dashboard/summary",
        params={
            "start": "2026-08-01T00:00:00Z",
            "end": "2026-09-01T00:00:00Z",
            "compare_start": "2026-07-01T00:00:00Z",
            "compare_end": "2026-08-01T00:00:00Z",
        },
    )

    assert response.status_code == 200
    [summary] = response.json()["currencies"]
    # The comparison period's voucher leg is excluded too — only CARD-PAST's
    # 500 counts, not the voucher account's 1000.
    assert summary["comparison"]["spending"] == 500
