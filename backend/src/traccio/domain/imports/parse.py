"""Pure parsing of a decoded import file into movements (ADR 0023).

:func:`parse_import` takes rows already decoded to ``header -> cell`` maps (the
service owns reading xlsx/csv bytes) and a :class:`ImportProfile`, and returns a
:class:`ParsedImport`: the importable movements plus one error per row that
yielded none. No I/O, no clock, no database — every classification is a function
of the row and the profile.

Money follows the same discipline as the Enable Banking adapter: parsed with
:class:`decimal.Decimal`, never ``float``; an amount that is not a whole number
of cents is refused, not rounded.

This module imports nothing outside ``domain/``.
"""

import hashlib
import re
from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

from traccio.domain.imports.models import (
    REASON_AMOUNT_SPLIT_MISMATCH,
    REASON_INVALID_AMOUNT,
    REASON_INVALID_DATE,
    REASON_MISSING_ID,
    REASON_UNKNOWN_STATUS,
    REASON_ZERO_AMOUNT,
    TARGET_PRIMARY,
    TARGET_VOUCHER,
    ImportRowError,
    ParsedImport,
    ParsedMovement,
)
from traccio.domain.imports.profiles import ImportProfile

_MINOR_UNIT_SCALE = Decimal(100)
_LEADING_NON_WORD = re.compile(r"^\W+", re.UNICODE)
_AMOUNT_NOISE = re.compile(r"[\s\u20ac\u0024\u00a3]", re.UNICODE)


def parse_import(rows: Sequence[Mapping[str, object]], *, profile: ImportProfile) -> ParsedImport:
    """Classify every decoded row against ``profile``.

    Parameters
    ----------
    rows : Sequence[Mapping[str, object]]
        One map per data row, keyed by header text. Cell values are whatever
        the decoder produced — ``str`` for CSV, and ``str`` / ``int`` /
        ``float`` / ``datetime`` / ``None`` for xlsx.
    profile : ImportProfile
        The layout to read them as.

    Returns
    -------
    ParsedImport
        ``movements`` in source order (a split row contributes up to two),
        ``errors`` one per row that produced nothing.
    """
    movements: list[ParsedMovement] = []
    errors: list[ImportRowError] = []
    for row_number, row in enumerate(rows, start=1):
        result = _parse_row(row, profile=profile, row_number=row_number)
        if isinstance(result, ImportRowError):
            errors.append(result)
        else:
            movements.extend(result)
    return ParsedImport(movements=tuple(movements), errors=tuple(errors))


def _parse_row(
    row: Mapping[str, object], *, profile: ImportProfile, row_number: int
) -> ImportRowError | list[ParsedMovement]:
    """Turn one row into its movements, or the single reason it yielded none."""
    if (
        profile.status_column is not None
        and _normalize_status(row.get(profile.status_column)) not in profile.status_ok_values
    ):
        return ImportRowError(row_number=row_number, reason=REASON_UNKNOWN_STATUS)

    try:
        value_date = _parse_date(
            row.get(profile.date_column), profile.date_formats, profile.timezone
        )
    except ValueError:
        return ImportRowError(row_number=row_number, reason=REASON_INVALID_DATE)

    description = _clean(row.get(profile.description_column))

    key_base: str | None = None
    if profile.id_column is not None:
        external_id = _clean(row.get(profile.id_column))
        if not external_id:
            return ImportRowError(row_number=row_number, reason=REASON_MISSING_ID)
        key_base = f"{profile.key}:{external_id}"

    try:
        parts = _amount_parts(row, profile=profile)
    except _SplitMismatchError:
        return ImportRowError(row_number=row_number, reason=REASON_AMOUNT_SPLIT_MISMATCH)
    except ValueError:
        return ImportRowError(row_number=row_number, reason=REASON_INVALID_AMOUNT)
    if not parts:
        return ImportRowError(row_number=row_number, reason=REASON_ZERO_AMOUNT)

    movements: list[ParsedMovement] = []
    for target, amount in parts:
        if key_base is not None:
            key = key_base if target == TARGET_PRIMARY else f"{key_base}:voucher"
        else:
            key = _derived_key(
                profile.key, value_date, amount, profile.currency, description, row_number
            )
        movements.append(
            ParsedMovement(
                row_number=row_number,
                target=target,
                external_key=key,
                amount=amount,
                currency=profile.currency,
                value_date=value_date,
                description=description,
            )
        )
    return movements


class _SplitMismatchError(Exception):
    """The parts of a split row do not sum to its stated total."""


def _amount_parts(row: Mapping[str, object], *, profile: ImportProfile) -> list[tuple[str, int]]:
    """Return the ``(target, cents)`` pairs a row contributes, zeros dropped.

    Raises
    ------
    ValueError
        An amount cell is not a number, or not a whole number of cents.
    _SplitMismatchError
        A split row's parts do not sum to its total.
    """
    if profile.split is not None:
        rule = profile.split
        total = _to_cents(_parse_decimal(row.get(rule.total_column)))
        primary = _to_cents(_parse_decimal(row.get(rule.primary_column)))
        voucher = _to_cents(_parse_decimal(row.get(rule.voucher_column)))
        if primary + voucher != total:
            raise _SplitMismatchError
        return [
            (target, cents)
            for target, cents in ((TARGET_PRIMARY, primary), (TARGET_VOUCHER, voucher))
            if cents != 0
        ]

    column = profile.amount_column
    assert column is not None  # profile invariant: split xor amount_column
    amount = _to_cents(_parse_decimal(row.get(column)))
    return [(TARGET_PRIMARY, amount)] if amount != 0 else []


def _clean(value: object) -> str:
    """Trim a cell to a string; ``None`` and blank cells become ``""``."""
    if value is None:
        return ""
    return str(value).strip()


def _normalize_status(value: object) -> str:
    """Strip a leading emoji and spaces, then casefold — ``"✅ Approvato"`` ->
    ``"approvato"``."""
    return _LEADING_NON_WORD.sub("", _clean(value)).strip().casefold()


def _parse_decimal(value: object) -> Decimal:
    """Parse an amount cell into an exact :class:`Decimal`.

    Accepts a number openpyxl already typed, or a string with a currency
    symbol, an Italian decimal comma, and thousands dots (``"-€1.234,56"``). A
    blank cell is zero.

    Raises
    ------
    ValueError
        The cell is neither blank, a number, nor a parseable amount string.
    """
    if value is None or (isinstance(value, str) and not value.strip()):
        return Decimal(0)
    if isinstance(value, bool):  # bool is an int subclass — never an amount
        raise ValueError("amount cell is a boolean")
    if isinstance(value, int | float | Decimal):
        try:
            return Decimal(str(value))
        except InvalidOperation as exc:  # e.g. a NaN float
            raise ValueError("amount cell is not a finite number") from exc

    # Drop every whitespace kind (incl. no-break spaces) and the currency
    # symbols the sources use, leaving digits, sign, and separators.
    text = _AMOUNT_NOISE.sub("", str(value))
    if "," in text:
        # Italian grouping: dots are thousands separators, comma is the decimal.
        text = text.replace(".", "").replace(",", ".")
    if not text or text in {"-", "+"}:
        raise ValueError("amount cell has no digits")
    try:
        return Decimal(text)
    except InvalidOperation as exc:
        raise ValueError("amount cell is not a parseable number") from exc


def _to_cents(amount: Decimal) -> int:
    """Scale an exact decimal to integer minor units, refusing sub-cent values."""
    scaled = amount * _MINOR_UNIT_SCALE
    if scaled != scaled.to_integral_value():
        raise ValueError("amount is not a whole number of cents")
    return int(scaled)


def _parse_date(value: object, formats: Sequence[str], timezone: str) -> datetime:
    """Parse a cell into a timezone-aware UTC datetime.

    A ``datetime``/``date`` openpyxl already produced is used directly; a
    string is tried against each ``formats`` pattern. A naive result is
    interpreted in ``timezone`` before conversion to UTC.

    Raises
    ------
    ValueError
        The cell is blank or matches no format.
    """
    zone = ZoneInfo(timezone)

    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, date):
        parsed = datetime(value.year, value.month, value.day)
    else:
        text = _clean(value)
        if not text:
            raise ValueError("date cell is blank")
        parsed = _strptime_any(text, formats)

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=zone)
    return parsed.astimezone(UTC)


def _strptime_any(text: str, formats: Sequence[str]) -> datetime:
    """Return the first ``strptime`` that matches ``text``, else raise ``ValueError``."""
    for fmt in formats:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    raise ValueError("date matches no configured format")


def _derived_key(
    profile_key: str,
    value_date: datetime,
    amount: int,
    currency: str,
    description: str,
    row_number: int,
) -> str:
    """A content hash key for a profile with no id column.

    Includes ``row_number`` so two byte-identical rows in one file both import
    (they are genuinely two movements) while a re-import of the same file
    reproduces the same keys and adds nothing.
    """
    material = "|".join(
        [value_date.isoformat(), str(amount), currency, description, str(row_number)]
    )
    digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    return f"{profile_key}:{digest}"
