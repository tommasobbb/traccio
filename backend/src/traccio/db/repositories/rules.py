"""Categorization-rule queries (ADR 0005)."""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    row_to_rule,
    rule_to_row,
)
from traccio.db.models import (
    RuleRow,
)
from traccio.domain.enums import (
    RuleMatchKind,
)
from traccio.domain.models import (
    Rule,
)


def create_rule(session: Session, *, rule: Rule) -> Rule:
    """Persist a new rule.

    The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    rule : Rule
        The domain rule to store.

    Returns
    -------
    Rule
        The persisted rule.
    """
    session.add(rule_to_row(rule))
    return rule


def get_rule(session: Session, *, user_id: UUID, rule_id: UUID) -> Rule | None:
    """Return a single rule by id, scoped by ``user_id``.

    Returns ``None`` when no rule with that id belongs to the user, so a
    request naming another user's (or an unknown) rule cannot read it.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rule; the query is scoped to it.
    rule_id : UUID
        The rule to fetch.

    Returns
    -------
    Rule or None
        The domain rule, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(RuleRow).where(RuleRow.id == rule_id, RuleRow.user_id == user_id)
    ).one_or_none()
    return None if row is None else row_to_rule(row)


def rule_exists(
    session: Session, *, user_id: UUID, match_kind: RuleMatchKind, pattern: str
) -> bool:
    """Return whether the user already has a rule with this exact predicate.

    A read-then-write check (rather than catching the unique constraint's
    ``IntegrityError``), matching the idiom :func:`category_name_exists` uses.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner to check within; the query is scoped to it.
    match_kind : RuleMatchKind
        The exact predicate to look for.
    pattern : str
        The exact pattern to look for (already normalized by the caller).

    Returns
    -------
    bool
        ``True`` if the user has a rule with this ``(match_kind, pattern)``.
    """
    return (
        session.scalars(
            select(RuleRow.id).where(
                RuleRow.user_id == user_id,
                RuleRow.match_kind == match_kind,
                RuleRow.pattern == pattern,
            )
        ).first()
        is not None
    )


def list_rules(session: Session, user_id: UUID) -> list[Rule]:
    """Return the user's rules, ordered by ``created_at`` then ``id``.

    This is creation order, not evaluation order — a rule's precedence depends
    on its pattern length, which only :func:`traccio.services.categorization.evaluation_order`
    computes. Callers that need the firing order apply it to this result; ``db/``
    may not import ``services/`` (see ``docs/architecture.md``).

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose rules to return; the query is scoped to it.

    Returns
    -------
    list[Rule]
        Domain rules owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(RuleRow).where(RuleRow.user_id == user_id).order_by(RuleRow.created_at, RuleRow.id)
    ).all()
    return [row_to_rule(row) for row in rows]


def delete_rule(session: Session, *, user_id: UUID, rule_id: UUID) -> Rule | None:
    """Delete a rule and return it, scoped by ``user_id``.

    Returns ``None`` when no rule with that id belongs to the user. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rule; the query and delete are scoped to it.
    rule_id : UUID
        The rule to delete.

    Returns
    -------
    Rule or None
        The deleted rule, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(RuleRow).where(RuleRow.id == rule_id, RuleRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    rule = row_to_rule(row)
    session.delete(row)
    return rule


def delete_rules_for_category(session: Session, *, user_id: UUID, category_id: UUID) -> int:
    """Delete every rule targeting ``category_id``, scoped by ``user_id``.

    Called from :func:`delete_category` when its target category is removed — a
    rule pointing at a category that no longer exists is broken, and the
    automation layer is disposable by design (same reasoning already applied to
    ``suggested_category_id`` there). The caller owns the transaction boundary
    and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the rules; the query and delete are scoped to it.
    category_id : UUID
        The category whose rules should be removed.

    Returns
    -------
    int
        The number of rules deleted.
    """
    rows = session.scalars(
        select(RuleRow).where(RuleRow.user_id == user_id, RuleRow.category_id == category_id)
    ).all()
    for row in rows:
        session.delete(row)
    return len(rows)
