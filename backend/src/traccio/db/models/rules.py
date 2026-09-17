"""Persisted :class:`~traccio.domain.models.Rule`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import RuleMatchKind


class RuleRow(Base):
    """Persisted :class:`~traccio.domain.models.Rule`.

    Unique on ``(user_id, match_kind, pattern)`` — the same predicate and
    pattern twice has no meaning. Applied by
    :mod:`traccio.services.categorization` to write
    ``transactions.suggested_category_id`` via
    :func:`traccio.db.repositories.set_suggested_categories`; deleting the
    target category also deletes rules pointing at it (handled in the
    repository, not a DB cascade, to stay portable).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    category_id : UUID
        The category assigned when this rule matches (foreign key, indexed).
    match_kind : RuleMatchKind
        The predicate applied to a transaction's ``description``.
    pattern : str
        The text to match against, case-insensitive. Never logged (see
        ``.claude/rules/data-safety.md``).
    created_at : datetime
        Creation timestamp (timezone-aware, UTC); the tiebreak when two rules
        match with an equal-length pattern.
    """

    __tablename__ = "rules"
    __table_args__ = (UniqueConstraint("user_id", "match_kind", "pattern"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    category_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("categories.id"), index=True)
    match_kind: Mapped[RuleMatchKind] = mapped_column(_enum_column(RuleMatchKind))
    pattern: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
