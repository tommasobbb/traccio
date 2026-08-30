"""Request and response schemas for the file-import endpoints (ADR 0023).

``POST /imports/preview`` classifies every movement a file would create —
``new``, ``already_imported``, or ``invalid`` — without writing anything;
``POST /imports/commit`` takes the same body and inserts only the ``new`` ones.
The file travels as base64 in a JSON body (the client is JSON-only and this
avoids a multipart dependency).
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

# Per-movement classification in a preview.
STATUS_NEW = "new"
STATUS_ALREADY_IMPORTED = "already_imported"
STATUS_INVALID = "invalid"


class ImportPreviewRequest(BaseModel):
    """Body for ``POST /imports/preview`` and ``POST /imports/commit``.

    Attributes
    ----------
    account_id : UUID
        The manual account the primary movements land on.
    voucher_account_id : UUID or None
        The manual account a split profile's voucher leg lands on. Required
        (``422 voucher_account_required``) when the file has non-zero voucher
        amounts; must differ from ``account_id``.
    profile : str
        An import profile key (``"satispay"``, ``"generic"``).
    filename : str
        The original file name — a format hint only (content sniffing wins).
    content_base64 : str
        The raw file, base64-encoded.
    """

    account_id: UUID
    voucher_account_id: UUID | None = None
    profile: str
    filename: str
    content_base64: str


class ImportRowResponse(BaseModel):
    """One movement a file would create, or one row that cannot be imported.

    Attributes
    ----------
    row_number : int
        1-based position of the source row (a split row appears twice, once
        per leg).
    status : str
        ``new``, ``already_imported``, or ``invalid``.
    reason : str or None
        A stable, value-free code for an ``invalid`` row (e.g.
        ``amount_split_mismatch``); ``None`` otherwise.
    target_account_id : UUID or None
        Which account this movement would land on; ``None`` for an ``invalid``
        row.
    amount : int or None
        Signed minor units; ``None`` for an ``invalid`` row.
    currency : str or None
        ISO 4217 code; ``None`` for an ``invalid`` row.
    value_date : datetime or None
        Timezone-aware UTC; ``None`` for an ``invalid`` row.
    description : str or None
        The row's description; ``None`` for an ``invalid`` row.
    """

    row_number: int
    status: str
    reason: str | None
    target_account_id: UUID | None
    amount: int | None
    currency: str | None
    value_date: datetime | None
    description: str | None


class ImportPreviewSummaryResponse(BaseModel):
    """Counts across a preview's rows.

    Attributes
    ----------
    new : int
        Movements that would be inserted.
    already_imported : int
        Movements whose key is already stored (a re-import); skipped.
    invalid : int
        Source rows that produced no movement.
    total : int
        ``new + already_imported + invalid``.
    """

    new: int
    already_imported: int
    invalid: int
    total: int


class ImportPreviewResponse(BaseModel):
    """The result of ``POST /imports/preview``.

    Attributes
    ----------
    rows : list[ImportRowResponse]
        Every movement or invalid row, in source order.
    summary : ImportPreviewSummaryResponse
        The counts.
    """

    rows: list[ImportRowResponse]
    summary: ImportPreviewSummaryResponse


class ImportCommitResponse(BaseModel):
    """The result of ``POST /imports/commit``.

    Attributes
    ----------
    imported : int
        Movements inserted.
    skipped : int
        Movements whose key was already stored, left untouched.
    invalid : int
        Source rows that produced no movement.
    """

    imported: int
    skipped: int
    invalid: int
