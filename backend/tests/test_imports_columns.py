"""Tests for canonical-column resolution (``domain/imports/columns.py``).

No I/O: a header row is a plain ``list[str]`` the way
``services/imports.decode_rows`` would return it. These cover the reason the
feature exists — a real Satispay export labels its id column
``"ID (Comunicalo all'Assistenza Clienti…)"``, not ``"ID"`` — plus the
normalisation and ambiguity rules. Values are synthetic
(``docs/engineering.md``).
"""

import unicodedata

from traccio.domain.imports.columns import (
    normalize_header,
    remap_rows,
    resolve_columns,
)
from traccio.domain.imports.profiles import GENERIC, SATISPAY

_SATISPAY_ID_HEADER = "ID (Comunicalo all'Assistenza Clienti in caso di problemi)"

# The real export header. ``resolve_columns`` matches the id column by
# word-boundary prefix and everything else exactly (after normalisation).
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
    _SATISPAY_ID_HEADER,
]


def test_normalize_header_folds_case_whitespace_and_nfc() -> None:
    assert normalize_header("  ID ") == "id"
    assert normalize_header("Buoni  Pasto") == "buoni pasto"
    nfd = unicodedata.normalize("NFD", "Disponibilità")
    assert nfd != "Disponibilità"  # genuinely decomposed
    assert normalize_header(nfd) == normalize_header("Disponibilità")


def test_real_satispay_header_resolves_with_no_missing() -> None:
    resolution = resolve_columns(_SATISPAY_HEADER, profile=SATISPAY)

    assert resolution.missing == ()
    assert resolution.columns["ID"] == _SATISPAY_ID_HEADER
    assert resolution.columns["Disponibilità"] == "Disponibilità"
    assert resolution.columns["Importo"] == "Importo"


def test_exact_match_wins_over_a_longer_prefix_sibling() -> None:
    # "Disponibilità" must take its own column, never be captured by
    # "Disponibilità dopo la transazione".
    header = [
        "Disponibilità dopo la transazione",
        "Disponibilità",
        _SATISPAY_ID_HEADER,
    ]
    resolution = resolve_columns(header, profile=SATISPAY)

    assert resolution.columns["Disponibilità"] == "Disponibilità"


def test_case_spacing_and_reordering_do_not_matter() -> None:
    header = [
        _SATISPAY_ID_HEADER,
        "buoni pasto",
        "  DISPONIBILITÀ  ",
        "stato",
        "importo",
        "NOME",
        "Data",
    ]
    resolution = resolve_columns(header, profile=SATISPAY)

    assert resolution.missing == ()
    assert resolution.columns["Buoni Pasto"] == "buoni pasto"
    assert resolution.columns["Disponibilità"] == "  DISPONIBILITÀ  "


def test_prefix_match_needs_a_word_boundary() -> None:
    # "Importont" starts with "importo" but not at a boundary, so "Importo"
    # stays unresolved and is reported missing.
    header = [
        "Data",
        "Nome",
        "Importont",
        "Stato",
        "Disponibilità",
        "Buoni Pasto",
        "ID",
    ]
    resolution = resolve_columns(header, profile=SATISPAY)

    assert "Importo" in resolution.missing


def test_an_ambiguous_prefix_resolves_to_nothing() -> None:
    header = [
        "Data",
        "Nome",
        "Importo",
        "Stato",
        "Disponibilità",
        "Buoni Pasto",
        "ID (prima colonna)",
        "ID (seconda colonna)",
    ]
    resolution = resolve_columns(header, profile=SATISPAY)

    assert resolution.missing == ("ID",)
    assert "ID" not in resolution.columns


def test_a_genuinely_absent_column_is_missing() -> None:
    header = [
        "Data",
        "Nome",
        "Importo",
        "Stato",
        "Disponibilità",
        _SATISPAY_ID_HEADER,
    ]
    resolution = resolve_columns(header, profile=SATISPAY)

    assert resolution.missing == ("Buoni Pasto",)


def test_generic_profile_is_now_case_insensitive() -> None:
    resolution = resolve_columns(["Date", "Amount", "Description"], profile=GENERIC)

    assert resolution.missing == ()
    assert resolution.columns["amount"] == "Amount"


def test_remap_rows_rekeys_to_canonical_names() -> None:
    resolution = resolve_columns(_SATISPAY_HEADER, profile=SATISPAY)
    row = {header: f"v-{header[:4]}" for header in _SATISPAY_HEADER}

    remapped = remap_rows([row], resolution.columns)

    assert remapped[0]["ID"] == row[_SATISPAY_ID_HEADER]
    assert set(remapped[0]) == set(resolution.columns)
