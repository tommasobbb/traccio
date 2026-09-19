"""Category endpoints: CRUD, the shared default tree, appearance, and moving.

A category is what kind of spending a transaction represents. Two layers on a
transaction (see ``docs/domain.md`` §Category): ``suggested_category_id``,
written by the categorization engine and overwritten freely, and
``confirmed_category_id``, written **only** by the confirm/clear endpoints on
the transactions router, never by automation.

Since ADR 0018, a category nests in a strict two-level hierarchy: a root, or a
child of a root — never deeper. ``POST /categories`` accepts an optional
``parent_id``; every other structural change goes through
``POST /categories/{id}/move``.

``POST /categories/defaults`` seeds the shared default tree once per user
(idempotent: a no-op once the user has at least one category), rather than
happening implicitly on ``GET /categories`` — a GET that writes would be a
hygiene break, and would silently resurrect defaults for a user who
deliberately deleted them.

Deleting a category refuses (``409``) when it has children, checked before
whether it is confirmed on any transaction — either refusal is a "this would
silently discard something the user organized deliberately" guard, and the
structural one (children) is checked first because it can never be worked
around by clearing a confirmation.

Data safety (``docs/engineering.md``): these handlers log only ids
and counts — **never a category name**, which is user-typed data.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, load_or_404
from traccio.api.schemas.categories import (
    CategoriesResponse,
    CategoryResponse,
    CreateCategoryRequest,
    MoveCategoryRequest,
    RenameCategoryRequest,
    SetCategoryAppearanceRequest,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    category_has_children,
    category_is_confirmed_on_any_transaction,
    category_name_exists,
    create_category,
    delete_category,
    get_category,
    list_categories,
    move_category,
    rename_category,
    seed_default_categories,
    set_category_appearance,
)
from traccio.db.session import get_session
from traccio.domain.categories import (
    CategoryError,
    default_child_color,
    normalize_category_name,
    validate_parent,
)
from traccio.domain.enums import PaletteColor
from traccio.domain.models import Category

logger = get_logger(__name__)

router = APIRouter()

# The transaction-category confirm/clear endpoints live on the transactions
# router instead (``api/routers/transactions.py``), not here: the path prefix
# owns the router, the same rule that puts ``/events/{id}/transactions`` on the
# events router rather than here.


def _load_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category:
    """Load a category owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_category`, so naming another user's (or
    an unknown) category is indistinguishable from "not found".
    """
    return load_or_404(
        lambda: get_category(session, user_id=user_id, category_id=category_id),
        detail="unknown category",
    )


@router.post("/categories", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
def create_category_endpoint(
    body: CreateCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoryResponse:
    """Create a category, optionally as a child of an existing root.

    Scoped to the current user. A ``404`` if ``parent_id`` is given but names
    an unknown (or another user's) category; a ``422`` if the name is blank
    or too long, or if ``parent_id`` names a category that is itself a child
    (``category_depth_exceeded``); a ``409`` if the (normalized) name collides
    with one of the user's existing categories, anywhere in the tree.

    Parameters
    ----------
    body : CreateCategoryRequest
        The category's name, optional parent, colour, and icon.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the category belongs to.

    Returns
    -------
    CategoryResponse
        The created category.
    """
    try:
        name = normalize_category_name(body.name)
    except CategoryError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
        ) from exc

    parent: Category | None = None
    if body.parent_id is not None:
        parent = get_category(session, user_id=user_id, category_id=body.parent_id)
        if parent is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="unknown parent category"
            )
        try:
            validate_parent(
                category_id=None, parent_id=body.parent_id, parent_parent_id=parent.parent_id
            )
        except CategoryError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
            ) from exc

    if category_name_exists(session, user_id=user_id, name=name):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="category_name_taken")

    color = body.color
    if color is None:
        color = default_child_color(parent.color) if parent is not None else PaletteColor.SLATE

    category = Category(
        user_id=user_id, name=name, parent_id=body.parent_id, color=color, icon=body.icon
    )
    created = create_category(session, category=category)
    session.commit()
    logger.info("categories.create", category_id=str(created.id))
    return CategoryResponse.from_domain(created)


@router.get("/categories", response_model=CategoriesResponse)
def categories(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoriesResponse:
    """List the current user's categories: roots, each followed by its children.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose categories to return.

    Returns
    -------
    CategoriesResponse
        The user's categories, flat with ``parent_id`` (empty if none) — see
        :func:`~traccio.db.repositories.list_categories` for the exact order.
    """
    found = list_categories(session, user_id)
    logger.info("categories.list", count=len(found))
    return CategoriesResponse(categories=[CategoryResponse.from_domain(c) for c in found])


@router.post("/categories/defaults", response_model=CategoriesResponse)
def seed_defaults(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoriesResponse:
    """Seed the shared default category tree, then return the user's full list.

    Idempotent: inserts the default tree only when the user currently has
    zero categories (see
    :func:`~traccio.db.repositories.seed_default_categories`), so calling it
    again after the user has renamed or deleted some is a no-op, never a
    resurrection. On an already-seeded account this stays a no-op even after
    the tree gains new default children in a later release — this endpoint
    only ever fires from zero.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user to seed.

    Returns
    -------
    CategoriesResponse
        The user's categories after seeding (the defaults, or whatever they
        already had).
    """
    created = seed_default_categories(session, user_id=user_id)
    session.commit()
    found = list_categories(session, user_id)
    logger.info("categories.seed", created=len(created), total=len(found))
    return CategoriesResponse(categories=[CategoryResponse.from_domain(c) for c in found])


@router.post("/categories/{category_id}/rename", response_model=CategoryResponse)
def rename_category_endpoint(
    category_id: UUID,
    body: RenameCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoryResponse:
    """Rename a category.

    A ``404`` if the category is unknown or not the caller's; a ``409`` if the
    new (normalized) name collides with a *different* one of the user's
    categories (renaming to the category's own current name is a no-op
    success); a ``422`` if the name is blank or too long.

    Parameters
    ----------
    category_id : UUID
        The category to rename.
    body : RenameCategoryRequest
        The new name.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the category belongs to.

    Returns
    -------
    CategoryResponse
        The category under its new name.
    """
    existing = _load_category(session, user_id=user_id, category_id=category_id)
    try:
        name = normalize_category_name(body.name)
    except CategoryError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
        ) from exc

    if name != existing.name and category_name_exists(session, user_id=user_id, name=name):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="category_name_taken")

    rename_category(session, user_id=user_id, category_id=category_id, name=name)
    session.commit()
    logger.info("categories.rename", category_id=str(category_id))
    updated = _load_category(session, user_id=user_id, category_id=category_id)
    return CategoryResponse.from_domain(updated)


@router.post("/categories/{category_id}/appearance", response_model=CategoryResponse)
def set_category_appearance_endpoint(
    category_id: UUID,
    body: SetCategoryAppearanceRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoryResponse:
    """Set a category's colour and icon.

    A full replace: both fields are applied together. A ``404`` if the
    category is unknown or not the caller's; an unrecognized colour or icon
    value is rejected by request validation before the handler runs
    (``422``).

    Parameters
    ----------
    category_id : UUID
        The category to restyle.
    body : SetCategoryAppearanceRequest
        The new colour and icon.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the category belongs to.

    Returns
    -------
    CategoryResponse
        The category under its new appearance.
    """
    _load_category(session, user_id=user_id, category_id=category_id)
    set_category_appearance(
        session, user_id=user_id, category_id=category_id, color=body.color, icon=body.icon
    )
    session.commit()
    logger.info("categories.appearance", category_id=str(category_id))
    updated = _load_category(session, user_id=user_id, category_id=category_id)
    return CategoryResponse.from_domain(updated)


@router.post("/categories/{category_id}/move", response_model=CategoryResponse)
def move_category_endpoint(
    category_id: UUID,
    body: MoveCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoryResponse:
    """Reparent a category — make it a root, or nest it under one.

    A ``404`` if the category, or (when given) the new parent, is unknown or
    not the caller's. A ``422`` if the new parent is the category itself
    (``category_self_parent``) or is itself a child
    (``category_depth_exceeded``). A ``409`` if the category being moved has
    children of its own and a non-``null`` parent was given — moving it would
    otherwise strand its children a third level deep, which the schema cannot
    express.

    Parameters
    ----------
    category_id : UUID
        The category to move.
    body : MoveCategoryRequest
        The new parent, or ``null`` to make it a root.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the category belongs to.

    Returns
    -------
    CategoryResponse
        The category under its new parent.
    """
    _load_category(session, user_id=user_id, category_id=category_id)

    if body.parent_id is not None:
        parent = get_category(session, user_id=user_id, category_id=body.parent_id)
        if parent is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="unknown parent category"
            )
        try:
            validate_parent(
                category_id=category_id, parent_id=body.parent_id, parent_parent_id=parent.parent_id
            )
        except CategoryError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
            ) from exc
        if category_has_children(session, user_id=user_id, category_id=category_id):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="category_has_children"
            )

    move_category(session, user_id=user_id, category_id=category_id, parent_id=body.parent_id)
    session.commit()
    logger.info("categories.move", category_id=str(category_id))
    updated = _load_category(session, user_id=user_id, category_id=category_id)
    return CategoryResponse.from_domain(updated)


@router.delete("/categories/{category_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_category(
    category_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a category.

    Refuses (``409 category_has_children``) when the category has children —
    checked first, since it can never be worked around from the client the way
    clearing a confirmation can. Refuses (``409 category_in_use``) when it is
    confirmed on any of the user's transactions — that layer is user-typed
    data, and nulling it as a side effect of this delete would be an automated
    write to ``confirmed_category_id`` (see the module docstring). Any
    ``suggested`` references are cleared, since that layer is disposable by
    design. A ``404`` if the category is unknown or not the caller's.

    Parameters
    ----------
    category_id : UUID
        The category to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the category belongs to.
    """
    _load_category(session, user_id=user_id, category_id=category_id)
    if category_has_children(session, user_id=user_id, category_id=category_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="category_has_children")
    if category_is_confirmed_on_any_transaction(session, user_id=user_id, category_id=category_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="category_in_use")

    delete_category(session, user_id=user_id, category_id=category_id)
    session.commit()
    logger.info("categories.delete", category_id=str(category_id))
