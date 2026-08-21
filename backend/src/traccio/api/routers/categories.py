"""Category endpoints: CRUD, the shared default set, and confirming.

A category is what kind of spending a transaction represents. Two layers on a
transaction (see ``docs/domain.md`` §Category): ``suggested_category_id``,
written by the categorization engine and overwritten freely (no engine exists
yet — that is a later slice, ``tasks/backlog.md`` §M2), and
``confirmed_category_id``, written **only** by the confirm/clear endpoints in
this module, never by automation.

``POST /categories/defaults`` seeds the shared default set once per user
(idempotent: a no-op once the user has at least one category), rather than
happening implicitly on ``GET /categories`` — a GET that writes would be a
hygiene break, and would silently resurrect defaults for a user who
deliberately deleted them.

Deleting a category refuses (``409``) when it is confirmed on any transaction —
that layer is user-typed data, and nulling it as a side effect of deleting a
different entity is exactly the automated write ``docs/domain.md`` forbids. Its
``suggested`` references are cleared instead, since that layer is disposable by
design.

Data safety (``.claude/rules/data-safety.md``): these handlers log only ids and
counts — **never a category name**, which is user-typed data.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id
from traccio.api.schemas.categories import (
    CategoriesResponse,
    CategoryResponse,
    CreateCategoryRequest,
    RenameCategoryRequest,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    category_is_confirmed_on_any_transaction,
    category_name_exists,
    create_category,
    delete_category,
    get_category,
    list_categories,
    rename_category,
    seed_default_categories,
)
from traccio.db.session import get_session
from traccio.domain.categories import CategoryError, normalize_category_name
from traccio.domain.models import Category

logger = get_logger(__name__)

router = APIRouter()

# The transaction-category confirm/clear endpoints live on the transactions
# router instead (``api/routers/transactions.py``), not here: the path prefix
# owns the router, the same rule that puts ``/events/{id}/transactions`` on the
# events router rather than the transactions one.


def _load_category(session: Session, *, user_id: UUID, category_id: UUID) -> Category:
    """Load a category owned by the user, or raise ``404``.

    Scoping is enforced by :func:`get_category`, so naming another user's (or
    an unknown) category is indistinguishable from "not found".
    """
    category = get_category(session, user_id=user_id, category_id=category_id)
    if category is None:
        raise HTTPException(status_code=404, detail="unknown category")
    return category


@router.post("/categories", response_model=CategoryResponse, status_code=status.HTTP_201_CREATED)
def create_category_endpoint(
    body: CreateCategoryRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoryResponse:
    """Create a category.

    Scoped to the current user. A ``409`` if the (normalized) name collides
    with one of the user's existing categories; a ``422`` if the name is blank
    or too long.

    Parameters
    ----------
    body : CreateCategoryRequest
        The category's name.
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
        raise HTTPException(status_code=422, detail=exc.reason) from exc

    if category_name_exists(session, user_id=user_id, name=name):
        raise HTTPException(status_code=409, detail="category_name_taken")

    category = Category(user_id=user_id, name=name)
    created = create_category(session, category=category)
    session.commit()
    logger.info("categories.create", category_id=str(created.id))
    return CategoryResponse.from_domain(created)


@router.get("/categories", response_model=CategoriesResponse)
def categories(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoriesResponse:
    """List the current user's categories, alphabetically by name.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose categories to return.

    Returns
    -------
    CategoriesResponse
        The user's categories, alphabetically (empty if none).
    """
    found = list_categories(session, user_id)
    logger.info("categories.list", count=len(found))
    return CategoriesResponse(categories=[CategoryResponse.from_domain(c) for c in found])


@router.post("/categories/defaults", response_model=CategoriesResponse)
def seed_defaults(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> CategoriesResponse:
    """Seed the shared default categories, then return the user's full list.

    Idempotent: inserts the default set only when the user currently has zero
    categories (see :func:`~traccio.db.repositories.seed_default_categories`),
    so calling it again after the user has renamed or deleted some is a no-op,
    never a resurrection.

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
    """Rename a category — its only mutation.

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
        raise HTTPException(status_code=422, detail=exc.reason) from exc

    if name != existing.name and category_name_exists(session, user_id=user_id, name=name):
        raise HTTPException(status_code=409, detail="category_name_taken")

    rename_category(session, user_id=user_id, category_id=category_id, name=name)
    session.commit()
    logger.info("categories.rename", category_id=str(category_id))
    updated = _load_category(session, user_id=user_id, category_id=category_id)
    return CategoryResponse.from_domain(updated)


@router.delete("/categories/{category_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_category(
    category_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a category.

    Refuses (``409``) when the category is confirmed on any of the user's
    transactions — that layer is user-typed data, and nulling it as a side
    effect of this delete would be an automated write to
    ``confirmed_category_id`` (see the module docstring). Any ``suggested``
    references are cleared, since that layer is disposable by design. A ``404``
    if the category is unknown or not the caller's.

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
    if category_is_confirmed_on_any_transaction(session, user_id=user_id, category_id=category_id):
        raise HTTPException(status_code=409, detail="category_in_use")

    delete_category(session, user_id=user_id, category_id=category_id)
    session.commit()
    logger.info("categories.delete", category_id=str(category_id))
