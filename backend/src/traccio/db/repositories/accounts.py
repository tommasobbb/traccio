"""Account queries: sync upserts, manual accounts, aliases, appearance, listing."""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    account_to_row,
    row_to_account,
)
from traccio.db.models import (
    AccountRow,
    TransactionRow,
)
from traccio.domain.enums import (
    AccountIcon,
    AccountKind,
    PaletteColor,
)
from traccio.domain.models import (
    Account,
)


def upsert_account(session: Session, *, account: Account) -> Account:
    """Insert an account or update it in place if already known.

    Idempotent on ``(user_id, identification_hash)``: an account re-exposed
    through a new consent updates the existing row (its ``connection_id``,
    ``kind``, ``currency``, ``name``) rather than duplicating, keeping the
    original ``id`` and ``created_at`` stable so downstream references survive a
    re-sync (see ``docs/architecture.md``). Scoped by ``user_id``. Uses a
    read-then-write pattern (no dialect-specific upsert) so it behaves the same
    on SQLite and PostgreSQL. The caller owns the transaction boundary and commits.

    Deliberately does **not** touch ``alias``, ``color``, or ``icon`` on an
    existing row — those are user-owned appearance fields (ADR 0017), and a
    sync overwriting them would silently discard whatever the user chose the
    next time their bank refreshes. This is the load-bearing line of the whole
    account-appearance feature: :func:`set_account_alias` and
    :func:`set_account_appearance` are the *only* writers of those three
    columns.

    Parameters
    ----------
    session : Session
        Active database session.
    account : Account
        The domain account to persist. Its ``user_id`` scopes the match.

    Returns
    -------
    Account
        The persisted account: the newly inserted one, or the existing one with
        its mutable fields refreshed (original ``id``/``created_at`` preserved).
    """
    existing = session.scalars(
        select(AccountRow).where(
            AccountRow.user_id == account.user_id,
            AccountRow.identification_hash == account.identification_hash,
        )
    ).one_or_none()
    if existing is None:
        row = account_to_row(account)
        session.add(row)
        return row_to_account(row)

    existing.connection_id = account.connection_id
    existing.kind = account.kind
    existing.currency = account.currency
    existing.name = account.name
    # existing.alias / .color / .icon: never written here — see the docstring.
    return row_to_account(existing)


def get_account(session: Session, *, user_id: UUID, account_id: UUID) -> Account | None:
    """Return a single account by id, scoped by ``user_id``.

    Returns ``None`` when no account with that id belongs to the user, so a
    request naming another user's (or an unknown) account cannot read or
    mutate it — the same cross-user gate :func:`get_category` provides.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the query is scoped to it.
    account_id : UUID
        The account to fetch.

    Returns
    -------
    Account or None
        The domain account, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AccountRow).where(AccountRow.id == account_id, AccountRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_account(row)


def set_account_alias(
    session: Session, *, user_id: UUID, account_id: UUID, alias: str | None
) -> None:
    """Set (or, with ``None``, clear) an account's user-chosen alias.

    Scoped by ``user_id``; a no-op if no row matches. The caller normalizes
    ``alias`` (see :func:`~traccio.domain.accounts.normalize_account_alias`)
    before calling this. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the update is scoped to it.
    account_id : UUID
        The account to rename.
    alias : str or None
        The new alias, or ``None`` to clear it and fall back to the provider
        name.
    """
    session.execute(
        update(AccountRow)
        .where(AccountRow.id == account_id, AccountRow.user_id == user_id)
        .values(alias=alias)
    )


def set_account_kind(
    session: Session, *, user_id: UUID, account_id: UUID, kind: AccountKind
) -> None:
    """Set a manual account's ``kind`` (e.g. converting Contanti to Buoni pasto).

    Scoped by ``user_id``; a no-op if no row matches. The caller has already
    verified the account is manual (``409 account_not_manual`` otherwise,
    same gate as :func:`delete_manual_account`) — a synced account's ``kind``
    is provider-derived and only :func:`upsert_account` may write it. The
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the update is scoped to it.
    account_id : UUID
        The account to reclassify.
    kind : AccountKind
        The new kind.
    """
    session.execute(
        update(AccountRow)
        .where(AccountRow.id == account_id, AccountRow.user_id == user_id)
        .values(kind=kind)
    )


def set_account_appearance(
    session: Session,
    *,
    user_id: UUID,
    account_id: UUID,
    color: PaletteColor | None,
    icon: AccountIcon | None,
) -> None:
    """Set an account's colour and icon tokens (a full replace, not a merge).

    Scoped by ``user_id``; a no-op if no row matches. Both tokens are set
    together — the request schema makes both mandatory-but-nullable, so there
    is no "leave the other one alone" case to support. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the update is scoped to it.
    account_id : UUID
        The account to restyle.
    color : PaletteColor or None
        The new colour token, or ``None`` to clear it.
    icon : AccountIcon or None
        The new icon token, or ``None`` to clear it.
    """
    session.execute(
        update(AccountRow)
        .where(AccountRow.id == account_id, AccountRow.user_id == user_id)
        .values(color=color, icon=icon)
    )


def list_accounts(session: Session, user_id: UUID) -> list[Account]:
    """Return the user's accounts, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose accounts to return; the query is scoped to it.

    Returns
    -------
    list[Account]
        Domain accounts owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(AccountRow).where(AccountRow.user_id == user_id).order_by(AccountRow.created_at)
    ).all()
    return [row_to_account(row) for row in rows]


def create_manual_account(session: Session, *, account: Account) -> Account:
    """Insert a manual account (ADR 0020) — a plain insert, never an upsert.

    Unlike :func:`upsert_account`, there is nothing to match on: a manual
    account has ``connection_id`` and ``identification_hash`` both ``None``, so
    every call creates a new row. The ``Account`` model validator has already
    guaranteed the account is manual-shaped. Scoped by ``account.user_id``; the
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    account : Account
        The manual account to persist.

    Returns
    -------
    Account
        The newly inserted account.
    """
    row = account_to_row(account)
    session.add(row)
    return row_to_account(row)


def account_has_transactions(session: Session, *, user_id: UUID, account_id: UUID) -> bool:
    """Return whether any transaction belongs to ``account_id``.

    Scoped by ``user_id``. Used to refuse deleting a manual account that still
    holds movements (``409 account_not_empty``), the same "refuse rather than
    cascade-delete financial data" stance as ``409 category_in_use``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the query is scoped to it.
    account_id : UUID
        The account to check.

    Returns
    -------
    bool
        ``True`` if at least one transaction references the account.
    """
    row = session.scalars(
        select(TransactionRow.id).where(
            TransactionRow.user_id == user_id,
            TransactionRow.account_id == account_id,
        )
    ).first()
    return row is not None


def delete_manual_account(session: Session, *, user_id: UUID, account_id: UUID) -> None:
    """Delete an account row, scoped by ``user_id``.

    A no-op if no row matches. The caller has already verified the account is
    manual and empty (see :func:`account_has_transactions`); this function only
    issues the ``DELETE``. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the account; the delete is scoped to it.
    account_id : UUID
        The account to delete.
    """
    session.execute(
        delete(AccountRow).where(AccountRow.id == account_id, AccountRow.user_id == user_id)
    )
