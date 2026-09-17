"""Persisted :class:`~traccio.domain.models.Category`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _token_column
from traccio.domain.enums import CategoryIcon, PaletteColor


class CategoryRow(Base):
    """Persisted :class:`~traccio.domain.models.Category`.

    User-scoped and unique on ``(user_id, name)`` **globally**, not per parent
    — two users may use the same name, and within one user's tree a child
    cannot share a name with any other of that user's categories, root or
    child (ADR 0018: kept simple rather than a ``(user_id, parent_id, name)``
    constraint, which is unreliable on PostgreSQL since ``NULL`` compares
    distinct to itself). Seeded from
    :func:`~traccio.domain.categories.default_categories` at
    :func:`traccio.db.repositories.seed_default_categories`, but every row is
    owned by its user from creation; there is no shared "global" row.

    ``parent_id`` is a self-referential foreign key, one level deep only —
    enforced in :mod:`traccio.domain.categories`
    (:func:`~traccio.domain.categories.validate_parent`), not by the schema,
    which cannot portably express "at most two levels."

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    name : str
        Human-readable name, unique per user across the whole tree.
    parent_id : UUID or None
        The root this category nests under (foreign key to this same table,
        indexed), or ``None`` if it is itself a root.
    color : PaletteColor
        The category's colour token. Never null — every creation path
        resolves one.
    icon : CategoryIcon or None
        The category's icon token, ``None`` until set.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "categories"
    __table_args__ = (UniqueConstraint("user_id", "name"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    parent_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("categories.id"), nullable=True, index=True
    )
    color: Mapped[PaletteColor] = mapped_column(_token_column(PaletteColor))
    icon: Mapped[CategoryIcon | None] = mapped_column(_token_column(CategoryIcon), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
