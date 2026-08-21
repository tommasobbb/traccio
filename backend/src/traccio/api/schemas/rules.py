"""Request and response schemas for the rule endpoints.

A rule is immutable once created (no rename/edit endpoint — its two fields,
``match_kind`` and ``pattern``, are what makes it a distinct rule at all; a
"rename" would just be delete-and-recreate, so there is no separate mutation to
support). See ``docs/domain.md`` §Rule.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.enums import RuleMatchKind
from traccio.domain.models import Rule


class CreateRuleRequest(BaseModel):
    """Body for creating a rule.

    Attributes
    ----------
    category_id : UUID
        The category to assign when this rule matches. Must belong to the
        caller.
    match_kind : RuleMatchKind
        The predicate to apply to a transaction's ``description``.
    pattern : str
        The text to match against. Stripped and validated by
        :func:`~traccio.domain.rules.normalize_rule_pattern`.
    """

    category_id: UUID
    match_kind: RuleMatchKind
    pattern: str


class RuleResponse(BaseModel):
    """One rule as returned to the client.

    Attributes
    ----------
    id : UUID
        Stable identifier of the rule.
    category_id : UUID
        The category assigned when this rule matches.
    match_kind : RuleMatchKind
        The predicate applied to a transaction's ``description``.
    pattern : str
        The text matched against. Returned to its owner over authenticated
        transport — it is merchant/counterparty text, never logged (see
        ``.claude/rules/data-safety.md``).
    created_at : datetime
        When the rule was created (timezone-aware, UTC).
    """

    id: UUID
    category_id: UUID
    match_kind: RuleMatchKind
    pattern: str
    created_at: datetime

    @classmethod
    def from_domain(cls, rule: Rule) -> "RuleResponse":
        """Project a domain :class:`~traccio.domain.models.Rule`."""
        return cls(
            id=rule.id,
            category_id=rule.category_id,
            match_kind=rule.match_kind,
            pattern=rule.pattern,
            created_at=rule.created_at,
        )


class RulesResponse(BaseModel):
    """Envelope for the rules list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    rules : list[RuleResponse]
        The user's rules, in evaluation order (the order they fire in — see
        :func:`traccio.services.categorization.evaluation_order`).
    """

    rules: list[RuleResponse]


class ApplyRulesResponse(BaseModel):
    """Result of recomputing every rule against the user's transactions.

    Attributes
    ----------
    rules_applied : int
        How many rules were evaluated.
    matched : int
        How many transactions were assigned a suggested category.
    cleared : int
        How many transactions had their suggested category cleared (no rule
        matched, including ones with a stale suggestion from a deleted rule).
    """

    rules_applied: int
    matched: int
    cleared: int
