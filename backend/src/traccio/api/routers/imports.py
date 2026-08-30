"""File-import endpoints: preview, then commit (ADR 0023).

Importing turns a spreadsheet or CSV of a feed Traccio cannot connect to
(Satispay today) into manual movements on a manual account. ``POST
/imports/preview`` classifies every movement the file would create without
writing anything; ``POST /imports/commit`` takes the same body and inserts only
the ``new`` ones. Re-importing the same file is a no-op — each movement's
``stable_key`` is ``"{profile}:{external_id}"`` and the ``(account_id,
stable_key)`` uniqueness deduplicates.

Data safety (``.claude/rules/data-safety.md``): these handlers log only counts
and stable reason codes — never a cell value, a description, or an amount.
"""

import base64
import binascii
from typing import Annotated, NamedTuple
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.imports import (
    STATUS_ALREADY_IMPORTED,
    STATUS_INVALID,
    STATUS_NEW,
    ImportCommitResponse,
    ImportPreviewRequest,
    ImportPreviewResponse,
    ImportPreviewSummaryResponse,
    ImportRowResponse,
)
from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    create_imported_transactions,
    get_account,
    imported_stable_keys,
)
from traccio.db.session import get_session
from traccio.domain.accounts import account_source
from traccio.domain.enums import (
    AccountSource,
    KeyStrategy,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.imports import PROFILES, ParsedImport, parse_import
from traccio.domain.imports.columns import remap_rows, resolve_columns
from traccio.domain.imports.models import TARGET_VOUCHER, ParsedMovement
from traccio.domain.imports.profiles import ImportProfile
from traccio.domain.models import Account, Transaction
from traccio.domain.money import Money
from traccio.services.imports import ImportDecodeError, decode_rows

logger = get_logger(__name__)

router = APIRouter()


class _Prepared(NamedTuple):
    """Everything preview and commit both need from a request body."""

    profile: ImportProfile
    primary: Account
    voucher: Account | None
    parsed: ParsedImport
    existing_keys: set[str]


def _load_manual_account(session: Session, *, user_id: UUID, account_id: UUID) -> Account:
    """Load a manual account owned by the user, or raise the right error."""
    account = get_account(session, user_id=user_id, account_id=account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="unknown account")
    if account_source(account) is not AccountSource.MANUAL:
        raise HTTPException(status_code=409, detail="account_not_manual")
    return account


def _prepare(body: ImportPreviewRequest, session: Session, user_id: UUID) -> _Prepared:
    """Decode, validate, and parse a request body — shared by both endpoints.

    Raises the HTTP error for every failure mode: ``422 invalid_base64`` /
    ``unknown_profile`` / ``voucher_account_same_as_primary`` /
    ``voucher_account_required`` / a decode reason, ``413 file_too_large``,
    ``404 unknown account``, ``409 account_not_manual``.
    """
    try:
        content = base64.b64decode(body.content_base64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=422, detail="invalid_base64") from exc
    if len(content) > get_settings().import_max_bytes:
        raise HTTPException(status_code=413, detail="file_too_large")

    profile = PROFILES.get(body.profile)
    if profile is None:
        raise HTTPException(status_code=422, detail="unknown_profile")

    primary = _load_manual_account(session, user_id=user_id, account_id=body.account_id)
    voucher: Account | None = None
    if body.voucher_account_id is not None:
        if body.voucher_account_id == body.account_id:
            raise HTTPException(status_code=422, detail="voucher_account_same_as_primary")
        voucher = _load_manual_account(session, user_id=user_id, account_id=body.voucher_account_id)

    try:
        header, rows = decode_rows(content, filename=body.filename)
    except ImportDecodeError as exc:
        raise HTTPException(status_code=422, detail=exc.reason) from exc
    resolution = resolve_columns(header, profile=profile)
    if resolution.missing:
        raise HTTPException(status_code=422, detail="missing_columns")

    parsed = parse_import(remap_rows(rows, resolution.columns), profile=profile)

    if any(m.target == TARGET_VOUCHER for m in parsed.movements) and voucher is None:
        raise HTTPException(status_code=422, detail="voucher_account_required")

    account_ids = [primary.id] + ([voucher.id] if voucher is not None else [])
    existing = imported_stable_keys(session, user_id=user_id, account_ids=account_ids)
    return _Prepared(profile, primary, voucher, parsed, existing)


def _target_account_id(movement: ParsedMovement, prepared: _Prepared) -> UUID:
    """Which account a movement lands on. ``voucher`` is guaranteed non-``None``
    for a voucher movement by :func:`_prepare`."""
    if movement.target == TARGET_VOUCHER:
        assert prepared.voucher is not None
        return prepared.voucher.id
    return prepared.primary.id


@router.post("/imports/preview", response_model=ImportPreviewResponse)
def preview_import(
    body: ImportPreviewRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ImportPreviewResponse:
    """Classify every movement a file would create, writing nothing.

    Each movement is ``new`` (would be inserted) or ``already_imported`` (its
    key is already stored); each unparseable source row is one ``invalid`` entry
    with a stable ``reason``. Scoped to the current user; every target account
    must be a manual one (``409 account_not_manual``).

    Parameters
    ----------
    body : ImportPreviewRequest
        The account(s), profile, filename, and base64 file content.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the accounts belong to.

    Returns
    -------
    ImportPreviewResponse
        Per-movement rows in source order, plus the counts.
    """
    prepared = _prepare(body, session, user_id)

    rows: list[ImportRowResponse] = []
    for movement in prepared.parsed.movements:
        is_stored = movement.external_key in prepared.existing_keys
        rows.append(
            ImportRowResponse(
                row_number=movement.row_number,
                status=STATUS_ALREADY_IMPORTED if is_stored else STATUS_NEW,
                reason=None,
                target_account_id=_target_account_id(movement, prepared),
                amount=movement.amount,
                currency=movement.currency,
                value_date=movement.value_date,
                description=movement.description,
            )
        )
    for error in prepared.parsed.errors:
        rows.append(
            ImportRowResponse(
                row_number=error.row_number,
                status=STATUS_INVALID,
                reason=error.reason,
                target_account_id=None,
                amount=None,
                currency=None,
                value_date=None,
                description=None,
            )
        )
    rows.sort(key=lambda r: (r.row_number, r.status))

    new = sum(1 for r in rows if r.status == STATUS_NEW)
    already = sum(1 for r in rows if r.status == STATUS_ALREADY_IMPORTED)
    invalid = sum(1 for r in rows if r.status == STATUS_INVALID)
    logger.info("imports.preview", new=new, already_imported=already, invalid=invalid)
    return ImportPreviewResponse(
        rows=rows,
        summary=ImportPreviewSummaryResponse(
            new=new, already_imported=already, invalid=invalid, total=len(rows)
        ),
    )


@router.post(
    "/imports/commit",
    response_model=ImportCommitResponse,
    status_code=status.HTTP_201_CREATED,
)
def commit_import(
    body: ImportPreviewRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ImportCommitResponse:
    """Insert the ``new`` movements a file would create.

    Same body and validation as the preview; only movements whose key is not
    already stored are inserted, so running it twice on the same file adds
    nothing the second time. Scoped to the current user.

    Parameters
    ----------
    body : ImportPreviewRequest
        The account(s), profile, filename, and base64 file content.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the accounts belong to.

    Returns
    -------
    ImportCommitResponse
        How many movements were inserted, skipped as already present, and how
        many source rows were invalid.
    """
    prepared = _prepare(body, session, user_id)

    to_insert: list[Transaction] = []
    skipped = 0
    for movement in prepared.parsed.movements:
        if movement.external_key in prepared.existing_keys:
            skipped += 1
            continue
        to_insert.append(
            Transaction(
                id=uuid4(),
                user_id=user_id,
                account_id=_target_account_id(movement, prepared),
                money=Money(amount=movement.amount, currency=movement.currency),
                booked_at=None,
                value_date=movement.value_date,
                description=movement.description,
                status=TransactionStatus.BOOKED,
                role=TransactionRole.PERSONAL,
                stable_key=movement.external_key,
                key_strategy=KeyStrategy.IMPORTED,
            )
        )

    imported = create_imported_transactions(session, transactions=to_insert)
    session.commit()

    invalid = len(prepared.parsed.errors)
    logger.info("imports.commit", imported=imported, skipped=skipped, invalid=invalid)
    return ImportCommitResponse(imported=imported, skipped=skipped, invalid=invalid)
