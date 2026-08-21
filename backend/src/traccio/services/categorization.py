"""Categorization: apply the user's rules, suggest, never confirm.

A :class:`~traccio.domain.models.Rule` maps a transaction pattern to a
:class:`~traccio.domain.models.Category`. Per the architecture invariant,
**detection never mutates**: this module only computes what
``suggested_category_id`` *should* be for a pool of transactions — writing it
is the caller's job (``db/repositories.py::set_suggested_categories``), and
``confirmed_category_id`` is never touched here or anywhere but the explicit
user-action endpoints.

This module is pure (no I/O) and imports only ``domain``.
"""

from collections.abc import Sequence
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.models import Rule, Transaction
from traccio.domain.rules import rule_matches


class CategorySuggestion(BaseModel):
    """One transaction's suggested category, or the lack of one.

    A suggestion, not a write — the caller decides whether and how to persist
    it. ``category_id`` is ``None`` when no rule matched, which is a real
    result: applying rules is a full recompute, so a transaction whose
    matching rule was deleted since the last run must have its stale
    suggestion cleared, not left untouched.

    Attributes
    ----------
    transaction_id : UUID
        The transaction this suggestion is for.
    category_id : UUID or None
        The category of the first matching rule in evaluation order, or
        ``None`` if no rule matched.
    rule_id : UUID or None
        The rule that produced ``category_id``, or ``None`` alongside it.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    transaction_id: UUID
    category_id: UUID | None
    rule_id: UUID | None


def evaluation_order(rules: Sequence[Rule]) -> list[Rule]:
    """Sort ``rules`` into the order they are evaluated and win in.

    The most specific rule wins: a longer ``pattern`` is assumed to be a more
    precise match (``"AMAZON PRIME"`` before ``"AMAZON"``), so the user raises
    a rule's precedence by sharpening its pattern rather than through a
    separate priority field. Ties (equal pattern length) break by
    ``created_at`` ascending, then ``id``, so the order is fully deterministic.

    Shared by :func:`suggest_categories` and the ``GET /rules`` listing so the
    order rules are shown in is the order they actually fire in — the same
    reasoning that keeps ``validate_transfer_pair`` sharing invariants with
    ``detect_transfers``.

    Parameters
    ----------
    rules : Sequence[Rule]
        The rules to order.

    Returns
    -------
    list[Rule]
        ``rules`` sorted most-specific first.
    """
    return sorted(rules, key=lambda rule: (-len(rule.pattern), rule.created_at, rule.id))


def suggest_categories(
    transactions: Sequence[Transaction], rules: Sequence[Rule]
) -> list[CategorySuggestion]:
    """Compute the suggested category for every transaction in ``transactions``.

    For each transaction, the first rule that matches in
    :func:`evaluation_order` wins; a transaction with no matching rule gets a
    ``None`` suggestion, clearing any stale one from a prior run. A
    transaction already carrying a ``confirmed_category_id`` still gets a
    suggestion computed — the suggestion layer is a pure function of
    ``(rules, transactions)`` and does not know about confirmation;
    :func:`~traccio.domain.categories.effective_category` is what makes the
    confirmed value win when both are present.

    Parameters
    ----------
    transactions : Sequence[Transaction]
        The pool to categorize, typically all of one user's transactions.
    rules : Sequence[Rule]
        The user's rules, typically all of one user's rules.

    Returns
    -------
    list[CategorySuggestion]
        One suggestion per transaction, in the input order.
    """
    ordered = evaluation_order(rules)
    suggestions: list[CategorySuggestion] = []
    for transaction in transactions:
        matched = next((rule for rule in ordered if rule_matches(rule, transaction)), None)
        suggestions.append(
            CategorySuggestion(
                transaction_id=transaction.id,
                category_id=matched.category_id if matched else None,
                rule_id=matched.id if matched else None,
            )
        )
    return suggestions
