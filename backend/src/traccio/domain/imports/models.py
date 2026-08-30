"""Value types for file import (ADR 0023).

An import turns a spreadsheet or CSV of a bank feed Traccio cannot connect to
(Satispay today) into manual movements. These types are the pure boundary
between :mod:`traccio.services.imports` (which reads bytes) and the API layer:
a :class:`ParsedImport` is what :func:`traccio.domain.imports.parse.parse_import`
produces from already-decoded rows, with no I/O.

This module imports nothing outside ``domain/``.
"""

from datetime import datetime

from pydantic import BaseModel, ConfigDict

# Stable, value-free reason codes for a row that cannot be imported. Exposed so
# the API and client can act on the cause without parsing a message; no amount,
# description, or other financial value ever appears in one.
REASON_INVALID_AMOUNT = "invalid_amount"
REASON_INVALID_DATE = "invalid_date"
REASON_MISSING_ID = "missing_id"
REASON_UNKNOWN_STATUS = "unknown_status"
REASON_AMOUNT_SPLIT_MISMATCH = "amount_split_mismatch"
REASON_ZERO_AMOUNT = "zero_amount"

# Which account a parsed movement belongs on. ``PRIMARY`` is the profile's main
# account (a Satispay balance movement); ``VOUCHER`` is the separate
# meal-voucher account a split row also feeds.
TARGET_PRIMARY = "primary"
TARGET_VOUCHER = "voucher"


class ImportRowError(BaseModel):
    """One source row that produced no importable movement.

    Attributes
    ----------
    row_number : int
        1-based position of the row in the file's data rows (the first row
        after the header is ``1``).
    reason : str
        A stable ``REASON_*`` code; never a message with a value in it.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    row_number: int
    reason: str


class ParsedMovement(BaseModel):
    """One movement a row resolved to, ready to become a manual transaction.

    A row yields one movement for a single-column profile, or up to two for a
    split profile (a balance leg and a voucher leg, each only when non-zero).

    Attributes
    ----------
    row_number : int
        1-based data-row position it came from (two movements from one split
        row share this).
    target : str
        :data:`TARGET_PRIMARY` or :data:`TARGET_VOUCHER` — which account it
        belongs on.
    external_key : str
        The deduplication key, ``"{profile}:{external_id}"`` (plus
        ``":voucher"`` for the voucher leg), or ``"{profile}:{hash}"`` when the
        profile has no id column. Stored verbatim as the transaction's
        ``stable_key``.
    amount : int
        Signed integer minor units (cents). Never zero.
    currency : str
        ISO 4217 code, fixed by the profile.
    value_date : datetime
        Timezone-aware UTC. There is no ``booked_at`` — an imported movement is
        always booked, like every manual one (ADR 0020).
    description : str
        The row's description column, verbatim and trimmed. May be empty.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    row_number: int
    target: str
    external_key: str
    amount: int
    currency: str
    value_date: datetime
    description: str


class ParsedImport(BaseModel):
    """The whole result of parsing a decoded file against a profile.

    Attributes
    ----------
    movements : tuple[ParsedMovement, ...]
        Every importable movement, in source-row order. A re-import produces
        the same set — deduplication against what is already stored happens in
        the service, not here.
    errors : tuple[ImportRowError, ...]
        One entry per row that yielded nothing, in source-row order.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    movements: tuple[ParsedMovement, ...]
    errors: tuple[ImportRowError, ...]
