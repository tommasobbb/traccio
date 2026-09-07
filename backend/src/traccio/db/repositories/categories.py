"""Category queries: the two-level hierarchy, appearance, and defaults (ADR 0018)."""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    category_to_row,
    row_to_category,
)
from traccio.db.models import (
    CategoryRow,
    TransactionRow,
)
from traccio.db.repositories.rules import delete_rules_for_category
from traccio.domain.categories import default_categories
from traccio.domain.enums import (
    CategoryIcon,
    PaletteColor,
)
from traccio.domain.models import (
    Category,
)


def create_category(session: Session, *, category: Category) -> Category:
    """Persist a new category.

    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    category : Category
        The domain category to store.

    Returns
    -------
    Category
        The persisted category.
    """
    session.add(category_to_row(category))
    return category


def get_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category | None:
    """Return a single category by id, scoped by ``user_id``.

    Returns ``None`` when no category with that id belongs to the user, so a
    request naming another user's (or an unknown) category cannot read it —
    this is the cross-user gate the category-confirming endpoints rely on.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the query is scoped to it.
    category_id : UUID
        The category to fetch.

    Returns
    -------
    Category or None
        The domain category, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(CategoryRow).where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_category(row)


def list_categories(session: Session, user_id: UUID) -> list[Category]:
    """Return the user's categories: each root, alphabetically, immediately
    followed by its own children, also alphabetically.

    A flat list — not nested — because every consumer (a picker, the rules
    editor, the filter chips) wants a flat list to render with indentation, not
    a tree to walk. The interleaving is done here, in Python, rather than with
    a self-join in SQL: a single ``ORDER BY name`` fetch, split into roots and
    a per-parent grouping, and re-merged — simpler to read than the SQL this
    would take, and correct because the two-level depth guarantee
    (:func:`~traccio.domain.categories.validate_parent`) means every child's
    parent is always a root already in this same list.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose categories to return; the query is scoped to it.

    Returns
    -------
    list[Category]
        Domain categories owned by ``user_id``: roots and children
        interleaved as described above (empty if none).
    """
    rows = session.scalars(
        select(CategoryRow).where(CategoryRow.user_id == user_id).order_by(CategoryRow.name)
    ).all()
    categories = [row_to_category(row) for row in rows]

    children_by_parent: dict[UUID, list[Category]] = {}
    for category in categories:
        if category.parent_id is not None:
            children_by_parent.setdefault(category.parent_id, []).append(category)

    ordered: list[Category] = []
    for category in categories:
        if category.parent_id is None:
            ordered.append(category)
            ordered.extend(children_by_parent.get(category.id, []))
    return ordered


def category_name_exists(session: Session, *, user_id: UUID, name: str) -> bool:
    """Return whether the user already has a category with this exact name.

    A read-then-write check (rather than catching the unique constraint's
    ``IntegrityError``) so create and rename behave identically on SQLite and
    PostgreSQL.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    name : str
        The exact name to look for (already normalized by the caller).

    Returns
    -------
    bool
        ``True`` if the user has a category with this name.
    """
    return (
        session.scalars(
            select(CategoryRow.id).where(CategoryRow.user_id == user_id, CategoryRow.name == name)
        ).first()
        is not None
    )


def rename_category(session: Session, *, user_id: UUID, category_id: UUID, name: str) -> None:
    """Rename a category, scoped by ``user_id``.

    A category's only mutable field. Scoped by ``user_id``; a no-op if no row
    matches. The caller checks the new name does not collide with another of the
    user's categories before calling this. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to rename.
    name : str
        The new name (already normalized by the caller).
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(name=name)
    )


def delete_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category | None:
    """Delete a category and return it, clearing its suggestions and rules first.

    Clears ``suggested_category_id`` on every transaction that references this
    category — that layer is "overwritten freely on every re-run"
    (``docs/domain.md`` §Category), so it is disposable and the categorization
    engine will re-fill it later. Also deletes every :class:`Rule` targeting this
    category (see :func:`delete_rules_for_category`): a rule pointing at a
    deleted category is broken, and the automation layer is disposable by the
    same reasoning. Both cleared explicitly (not via a DB cascade) to stay
    portable across SQLite and PostgreSQL, and so the delete does not violate a
    plain foreign key.

    Does **not** touch ``confirmed_category_id`` — the caller (the API layer)
    is expected to have already refused the delete via
    :func:`category_is_confirmed_on_any_transaction` when any transaction has
    this category confirmed; nulling user-confirmed data as a side effect of
    deleting a different entity is exactly the automated write to
    ``confirmed_category_id`` the project rule forbids. Returns ``None`` when no
    category with that id belongs to the user. The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the query and delete are scoped to it.
    category_id : UUID
        The category to delete.

    Returns
    -------
    Category or None
        The deleted category, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(CategoryRow).where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    category = row_to_category(row)
    session.execute(
        update(TransactionRow)
        .where(
            TransactionRow.user_id == user_id,
            TransactionRow.suggested_category_id == category_id,
        )
        .values(suggested_category_id=None)
    )
    delete_rules_for_category(session, user_id=user_id, category_id=category_id)
    session.delete(row)
    return category


def category_is_confirmed_on_any_transaction(
    session: Session, *, user_id: UUID, category_id: UUID
) -> bool:
    """Return whether any of the user's transactions has this category confirmed.

    The guard behind refusing to delete a category still in active use: the API
    layer calls this before :func:`delete_category` and returns ``409`` if it is
    ``True``, since deleting would otherwise require nulling user-confirmed data
    (see :func:`delete_category`).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    category_id : UUID
        The category to check.

    Returns
    -------
    bool
        ``True`` if at least one of the user's transactions has this category as
        its ``confirmed_category_id``.
    """
    return (
        session.scalars(
            select(TransactionRow.id).where(
                TransactionRow.user_id == user_id,
                TransactionRow.confirmed_category_id == category_id,
            )
        ).first()
        is not None
    )


def list_child_category_ids(session: Session, *, user_id: UUID, category_id: UUID) -> list[UUID]:
    """Return the ids of a category's direct children, scoped by ``user_id``.

    Always empty for a category that is itself a child — the two-level
    hierarchy means a child never has children of its own
    (:func:`~traccio.domain.categories.validate_parent`).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    category_id : UUID
        The (presumed root) category to find children of.

    Returns
    -------
    list[UUID]
        The ids of every category whose ``parent_id`` is ``category_id``
        (empty if none, including when ``category_id`` does not exist).
    """
    return list(
        session.scalars(
            select(CategoryRow.id).where(
                CategoryRow.user_id == user_id, CategoryRow.parent_id == category_id
            )
        ).all()
    )


def category_has_children(session: Session, *, user_id: UUID, category_id: UUID) -> bool:
    """Return whether a category has at least one direct child.

    The guard behind refusing to delete a parent, and behind refusing to move
    a category-with-children under another root (both would otherwise
    silently orphan or re-parent rows the user organized deliberately).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    category_id : UUID
        The category to check.

    Returns
    -------
    bool
        ``True`` if at least one of the user's categories has this one as its
        ``parent_id``.
    """
    return (
        session.scalars(
            select(CategoryRow.id).where(
                CategoryRow.user_id == user_id, CategoryRow.parent_id == category_id
            )
        ).first()
        is not None
    )


def set_category_appearance(
    session: Session,
    *,
    user_id: UUID,
    category_id: UUID,
    color: PaletteColor,
    icon: CategoryIcon | None,
) -> None:
    """Set a category's colour and icon, scoped by ``user_id``.

    A full replace: both fields are applied together, mirroring
    :func:`set_account_appearance`. Unlike an account's colour, a category's
    ``color`` is never ``None`` — every creation path already resolved one.
    Scoped by ``user_id``; a no-op if no row matches. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to restyle.
    color : PaletteColor
        The new colour.
    icon : CategoryIcon or None
        The new icon, or ``None`` to clear it.
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(color=color, icon=icon)
    )


def move_category(
    session: Session, *, user_id: UUID, category_id: UUID, parent_id: UUID | None
) -> None:
    """Set a category's parent, scoped by ``user_id``.

    The caller validates the move first
    (:func:`~traccio.domain.categories.validate_parent` for depth/self-parent,
    :func:`category_has_children` for "moving a category-with-children under
    another root would silently strand its own children two levels deep") —
    this function performs the write unconditionally. A no-op if no row
    matches. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the category; the update is scoped to it.
    category_id : UUID
        The category to move.
    parent_id : UUID or None
        The new parent, or ``None`` to make this category a root.
    """
    session.execute(
        update(CategoryRow)
        .where(CategoryRow.id == category_id, CategoryRow.user_id == user_id)
        .values(parent_id=parent_id)
    )


def seed_default_categories(session: Session, *, user_id: UUID) -> list[Category]:
    """Create the shared default categories for a user, once.

    Idempotent by construction: inserts :func:`~traccio.domain.categories.default_categories`
    only when the user currently has zero categories, so a user who deliberately
    deleted all of theirs does not have them silently resurrected on a repeat
    call. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        The user to seed.

    Returns
    -------
    list[Category]
        The categories just created, or an empty list if the user already had
        at least one.
    """
    existing = session.scalars(select(CategoryRow.id).where(CategoryRow.user_id == user_id)).first()
    if existing is not None:
        return []
    created = default_categories(user_id)
    for category in created:
        session.add(category_to_row(category))
    return created
