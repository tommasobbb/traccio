"""Import profiles: a file layout described as data, not code (ADR 0023).

A profile names the columns by *canonical* header text, the date format and
timezone, the decimal conventions, the fixed currency, and — for a source that
splits an amount across two accounts, like Satispay's balance vs. meal
vouchers — a :class:`SplitRule`. Adding a second source is a new
:class:`ImportProfile` constant here, not new parsing code.

The names here are canonical, not literal: a real export may reorder them,
change their case or spacing, or append a note in parentheses (Satispay labels
its id column ``"ID (Comunicalo all'Assistenza Clienti…)"``).
:func:`traccio.domain.imports.columns.resolve_columns` maps the file's real
headers onto these — an exact normalised match, then a unique word-boundary
prefix match — so the parser can keep looking each column up by the short name.

This module imports nothing outside ``domain/``.
"""

from pydantic import BaseModel, ConfigDict


class SplitRule(BaseModel):
    """A row whose total is split across a primary and a voucher account.

    Satispay: ``Importo`` = ``Disponibilità`` (balance) + ``Buoni Pasto``
    (meal vouchers). The two parts become two movements on two manual
    accounts; the parser refuses the row if they do not sum to the total.

    Attributes
    ----------
    total_column : str
        Header of the total amount, validated against the two parts.
    primary_column : str
        Header of the part that goes on the profile's main account.
    voucher_column : str
        Header of the part that goes on the separate voucher account.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    total_column: str
    primary_column: str
    voucher_column: str


class ImportProfile(BaseModel):
    """How to read one source's export.

    Attributes
    ----------
    key : str
        Stable identifier, also the ``stable_key`` prefix (``"satispay:..."``).
    required_headers : tuple[str, ...]
        Canonical names that must resolve to a column
        (:func:`traccio.domain.imports.columns.resolve_columns`); one that does
        not is a ``422`` before any row is read.
    date_column : str
        Header of the value date.
    date_formats : tuple[str, ...]
        ``strptime`` patterns tried in order (a cell openpyxl already gave as
        a ``datetime`` skips this).
    timezone : str
        IANA name the naive date is interpreted in before conversion to UTC.
    description_column : str
        Header whose trimmed text becomes the movement description.
    currency : str
        ISO 4217 code applied to every movement (the sources so far are
        single-currency and carry no currency column).
    id_column : str or None
        Header of a stable per-row id. ``None`` falls back to a content hash.
    status_column : str or None
        Header of a status/approval column, or ``None`` to accept every row.
    status_ok_values : tuple[str, ...]
        Casefolded values (after stripping a leading emoji and spaces) that
        count as importable; any other value makes the row ``unknown_status``.
    amount_column : str or None
        Header of the single signed amount, for a non-split profile.
    split : SplitRule or None
        Set instead of ``amount_column`` for a source that splits the amount.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    key: str
    required_headers: tuple[str, ...]
    date_column: str
    date_formats: tuple[str, ...]
    timezone: str
    description_column: str
    currency: str
    id_column: str | None
    status_column: str | None
    status_ok_values: tuple[str, ...]
    amount_column: str | None
    split: SplitRule | None


SATISPAY = ImportProfile(
    key="satispay",
    required_headers=(
        "Data",
        "Nome",
        "Importo",
        "Stato",
        "Disponibilità",
        "Buoni Pasto",
        "ID",
    ),
    date_column="Data",
    date_formats=("%d/%m/%Y %H:%M",),
    timezone="Europe/Rome",
    description_column="Nome",
    currency="EUR",
    id_column="ID",
    status_column="Stato",
    status_ok_values=("approvato",),
    amount_column=None,
    split=SplitRule(
        total_column="Importo",
        primary_column="Disponibilità",
        voucher_column="Buoni Pasto",
    ),
)

GENERIC = ImportProfile(
    key="generic",
    required_headers=("date", "amount", "description"),
    date_column="date",
    date_formats=(
        "%Y-%m-%d",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%d/%m/%Y",
        "%d/%m/%Y %H:%M",
    ),
    timezone="UTC",
    description_column="description",
    currency="EUR",
    id_column=None,
    status_column=None,
    status_ok_values=(),
    amount_column="amount",
    split=None,
)

PROFILES: dict[str, ImportProfile] = {profile.key: profile for profile in (SATISPAY, GENERIC)}
