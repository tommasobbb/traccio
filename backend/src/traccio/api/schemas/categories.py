"""Request and response schemas for the category endpoints.

A category is user-scoped and has exactly one mutable field, its name (see
``docs/domain.md`` §Category). There is no PATCH in this codebase, and one
mutable field does not earn one — renaming is its own endpoint
(``POST /categories/{id}/rename``), matching the state-change idiom already
used for events (``close``/``reopen``) and advances (``write-off``).
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.models import Category


class CreateCategoryRequest(BaseModel):
    """Body for creating a category.

    Attributes
    ----------
    name : str
        The category's name, e.g. ``"Groceries"``. Stripped and validated by
        :func:`~traccio.domain.categories.normalize_category_name`.
    """

    name: str


class RenameCategoryRequest(BaseModel):
    """Body for renaming a category.

    Attributes
    ----------
    name : str
        The new name. Stripped and validated by
        :func:`~traccio.domain.categories.normalize_category_name`.
    """

    name: str


class CategoryResponse(BaseModel):
    """One category as returned to the client.

    Attributes
    ----------
    id : UUID
        Stable identifier of the category.
    name : str
        Human-readable name.
    created_at : datetime
        When the category was created (timezone-aware, UTC).
    """

    id: UUID
    name: str
    created_at: datetime

    @classmethod
    def from_domain(cls, category: Category) -> "CategoryResponse":
        """Project a domain :class:`~traccio.domain.models.Category`."""
        return cls(id=category.id, name=category.name, created_at=category.created_at)


class CategoriesResponse(BaseModel):
    """Envelope for the categories list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    categories : list[CategoryResponse]
        The user's categories, alphabetically by name.
    """

    categories: list[CategoryResponse]
