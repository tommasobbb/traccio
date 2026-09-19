"""Tests for the pure import parser (``domain/imports/parse.py``).

No I/O: rows are built as ``header -> cell`` maps the way
``services/imports.decode_rows`` would produce them. Fixtures are synthetic
(invented ids, round amounts, ``"TEST MERCHANT 01"`` — ``docs/engineering.md``).
"""

from datetime import UTC, datetime

from traccio.domain.imports import parse_import
from traccio.domain.imports.models import (
    REASON_AMOUNT_SPLIT_MISMATCH,
    REASON_INVALID_AMOUNT,
    REASON_INVALID_DATE,
    REASON_MISSING_ID,
    REASON_UNKNOWN_STATUS,
    REASON_ZERO_AMOUNT,
    TARGET_PRIMARY,
    TARGET_VOUCHER,
)
from traccio.domain.imports.profiles import GENERIC, SATISPAY


def _satispay_row(
    *,
    data: object = "25/06/2026 21:56",
    nome: str = "TEST MERCHANT 01",
    importo: object = "-€42,00",
    stato: object = "✅ Approvato",
    disponibilita: object = "-€2,00",
    buoni_pasto: object = "-€40,00",
    row_id: object = "019f005a-9877-7777-90a3-fa4fdec9e106",
) -> dict[str, object]:
    return {
        "Data": data,
        "Nome": nome,
        "Descrizione": "",
        "Importo": importo,
        "Tipo": "🏪 a un Negozio",
        "Stato": stato,
        "Disponibilità": disponibilita,
        "Buoni Pasto": buoni_pasto,
        "Disponibilità dopo la transazione": "€12,63",
        "ID": row_id,
    }


def test_a_balance_only_row_yields_one_primary_movement() -> None:
    row = _satispay_row(importo="-€9,00", disponibilita="-€9,00", buoni_pasto="")

    parsed = parse_import([row], profile=SATISPAY)

    assert parsed.errors == ()
    [movement] = parsed.movements
    assert movement.target == TARGET_PRIMARY
    assert movement.amount == -900
    assert movement.currency == "EUR"
    assert movement.description == "TEST MERCHANT 01"
    assert movement.external_key == "satispay:019f005a-9877-7777-90a3-fa4fdec9e106"


def test_a_mixed_row_splits_into_two_movements() -> None:
    parsed = parse_import([_satispay_row()], profile=SATISPAY)

    assert parsed.errors == ()
    primary, voucher = parsed.movements
    assert (primary.target, primary.amount) == (TARGET_PRIMARY, -200)
    assert (voucher.target, voucher.amount) == (TARGET_VOUCHER, -4000)
    assert primary.external_key == "satispay:019f005a-9877-7777-90a3-fa4fdec9e106"
    assert voucher.external_key == "satispay:019f005a-9877-7777-90a3-fa4fdec9e106:voucher"
    assert primary.row_number == voucher.row_number == 1


def test_a_voucher_only_row_yields_one_voucher_movement() -> None:
    row = _satispay_row(importo="-€10,00", disponibilita="", buoni_pasto="-€10,00")

    [movement] = parse_import([row], profile=SATISPAY).movements

    assert movement.target == TARGET_VOUCHER
    assert movement.amount == -1000


def test_italian_decimals_and_the_recharge_sign() -> None:
    row = _satispay_row(importo="€20,71", disponibilita="€20,71", buoni_pasto="")

    [movement] = parse_import([row], profile=SATISPAY).movements

    assert movement.amount == 2071


def test_thousands_separator_is_handled() -> None:
    row = _satispay_row(importo="-€1.234,56", disponibilita="-€1.234,56", buoni_pasto="")

    [movement] = parse_import([row], profile=SATISPAY).movements

    assert movement.amount == -123456


def test_a_string_date_is_read_in_rome_time_and_stored_utc() -> None:
    row = _satispay_row(
        data="25/06/2026 21:56", importo="-€1,00", disponibilita="-€1,00", buoni_pasto=""
    )

    [movement] = parse_import([row], profile=SATISPAY).movements

    # 21:56 CEST (UTC+2) -> 19:56 UTC.
    assert movement.value_date == datetime(2026, 6, 25, 19, 56, tzinfo=UTC)


def test_a_typed_datetime_cell_is_localized_the_same_way() -> None:
    row = _satispay_row(
        data=datetime(2026, 1, 15, 8, 0),  # naive, as openpyxl hands it over
        importo="-€1,00",
        disponibilita="-€1,00",
        buoni_pasto="",
    )

    [movement] = parse_import([row], profile=SATISPAY).movements

    # 08:00 CET (UTC+1) -> 07:00 UTC.
    assert movement.value_date == datetime(2026, 1, 15, 7, 0, tzinfo=UTC)


def test_an_unknown_status_is_an_error_not_a_movement() -> None:
    parsed = parse_import([_satispay_row(stato="❌ Rifiutato")], profile=SATISPAY)

    assert parsed.movements == ()
    [error] = parsed.errors
    assert (error.row_number, error.reason) == (1, REASON_UNKNOWN_STATUS)


def test_a_split_that_does_not_sum_is_rejected() -> None:
    row = _satispay_row(importo="-€42,00", disponibilita="-€2,00", buoni_pasto="-€39,00")

    parsed = parse_import([row], profile=SATISPAY)

    assert parsed.movements == ()
    assert parsed.errors[0].reason == REASON_AMOUNT_SPLIT_MISMATCH


def test_a_missing_id_is_rejected() -> None:
    parsed = parse_import([_satispay_row(row_id="")], profile=SATISPAY)

    assert parsed.errors[0].reason == REASON_MISSING_ID


def test_a_wholly_zero_row_is_rejected() -> None:
    row = _satispay_row(importo="€0,00", disponibilita="€0,00", buoni_pasto="€0,00")

    parsed = parse_import([row], profile=SATISPAY)

    assert parsed.errors[0].reason == REASON_ZERO_AMOUNT


def test_a_sub_cent_amount_is_refused() -> None:
    row = _satispay_row(importo="-€1,005", disponibilita="-€1,005", buoni_pasto="")

    parsed = parse_import([row], profile=SATISPAY)

    assert parsed.errors[0].reason == REASON_INVALID_AMOUNT


def test_an_unparseable_date_is_an_error() -> None:
    parsed = parse_import([_satispay_row(data="not a date")], profile=SATISPAY)

    assert parsed.errors[0].reason == REASON_INVALID_DATE


def test_row_numbers_count_data_rows_from_one() -> None:
    rows = [
        _satispay_row(row_id="id-a", importo="-€1,00", disponibilita="-€1,00", buoni_pasto=""),
        _satispay_row(stato="❌ Annullato"),
        _satispay_row(row_id="id-c", importo="-€3,00", disponibilita="-€3,00", buoni_pasto=""),
    ]

    parsed = parse_import(rows, profile=SATISPAY)

    assert [m.row_number for m in parsed.movements] == [1, 3]
    assert [e.row_number for e in parsed.errors] == [2]


def test_generic_profile_derives_a_key_per_row_so_identical_rows_both_import() -> None:
    rows = [
        {"date": "2026-03-01", "amount": "-12.34", "description": "TEST MERCHANT 01"},
        {"date": "2026-03-01", "amount": "-12.34", "description": "TEST MERCHANT 01"},
    ]

    parsed = parse_import(rows, profile=GENERIC)

    assert parsed.errors == ()
    first, second = parsed.movements
    assert first.amount == second.amount == -1234
    assert first.external_key != second.external_key
    assert first.external_key.startswith("generic:")
