"""Request and response schemas for the category endpoints.

A category is user-scoped and, since ADR 0018, nests in a strict two-level
hierarchy plus carries a colour and icon (ADR 0017). There is no PATCH in this
codebase: each mutable concern is its own endpoint — renaming
(``POST /categories/{id}/rename``), restyling
(``POST /categories/{id}/appearance``), and reparenting
(``POST /categories/{id}/move``) — matching the state-change idiom already
used for events (``close``/``reopen``) and advances (``write-off``).
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.enums import CategoryIcon, PaletteColor
from traccio.domain.models import Category


class CreateCategoryRequest(BaseModel):
    """Body for creating a category.

    Attributes
    ----------
    name : str
        The category's name, e.g. ``"Alimentari"``. Stripped and validated by
        :func:`~traccio.domain.categories.normalize_category_name`.
    parent_id : UUID or None
        The root this category should nest under, or ``None`` (the default)
        to create a root. Validated by
        :func:`~traccio.domain.categories.validate_parent` — a parent that is
        itself a child is rejected, not silently flattened.
    color : PaletteColor or None
        The category's colour, or ``None`` to default to the parent's own
        colour (a child) or
        :attr:`~traccio.domain.enums.PaletteColor.SLATE` (a root).
    icon : CategoryIcon or None
        The category's icon, or ``None`` to leave it unset.
    """

    name: str
    parent_id: UUID | None = None
    color: PaletteColor | None = None
    icon: CategoryIcon | None = None


class RenameCategoryRequest(BaseModel):
    """Body for renaming a category.

    Attributes
    ----------
    name : str
        The new name. Stripped and validated by
        :func:`~traccio.domain.categories.normalize_category_name`.
    """

    name: str


class SetCategoryAppearanceRequest(BaseModel):
    """Body for setting a category's colour and icon.

    A full replace, not a partial update — mirrors
    ``SetAccountAppearanceRequest``. Unlike an account's colour, ``color`` is
    mandatory and never ``null``: every category always has one.

    Attributes
    ----------
    color : PaletteColor
        The new colour.
    icon : CategoryIcon or None
        The new icon, or ``None`` to clear it.
    """

    color: PaletteColor
    icon: CategoryIcon | None


class MoveCategoryRequest(BaseModel):
    """Body for reparenting a category.

    Attributes
    ----------
    parent_id : UUID or None
        The new parent, or ``None`` to make this category a root.
    """

    parent_id: UUID | None


class CategoryResponse(BaseModel):
    """One category as returned to the client.

    Attributes
    ----------
    id : UUID
        Stable identifier of the category.
    name : str
        Human-readable name.
    parent_id : UUID or None
        The root this category nests under, or ``None`` if it is itself a
        root.
    color : PaletteColor
        The category's colour.
    icon : CategoryIcon or None
        The category's icon, or ``None`` if unset.
    created_at : datetime
        When the category was created (timezone-aware, UTC).
    """

    id: UUID
    name: str
    parent_id: UUID | None
    color: PaletteColor
    icon: CategoryIcon | None
    created_at: datetime

    @classmethod
    def from_domain(cls, category: Category) -> "CategoryResponse":
        """Project a domain :class:`~traccio.domain.models.Category`."""
        return cls(
            id=category.id,
            name=category.name,
            parent_id=category.parent_id,
            color=category.color,
            icon=category.icon,
            created_at=category.created_at,
        )


class CategoriesResponse(BaseModel):
    """Envelope for the categories list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    categories : list[CategoryResponse]
        The user's categories: each root, alphabetically, immediately
        followed by its own children, also alphabetically (see
        :func:`~traccio.db.repositories.list_categories`).
    """

    categories: list[CategoryResponse]
