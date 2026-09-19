"""Rule endpoints: create, list, delete, and apply against transactions.

A rule maps a transaction pattern to a category and is applied by the
categorization engine (:mod:`traccio.services.categorization`) to write
``suggested_category_id`` — never ``confirmed_category_id`` (see
``docs/domain.md`` §Rule and ``docs/architecture.md``: "detection never
mutates"). ``POST /rules/apply`` is the only path that writes: it recomputes
every one of the user's transactions from scratch, so a stale suggestion whose
rule was deleted since the last run gets cleared, keeping the operation
idempotent.

Data safety (``docs/engineering.md``): a rule's ``pattern`` is
merchant/counterparty text. These handlers log only ids and counts — **never a
pattern**.
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from traccio.api.deps import current_user_id, load_or_404
from traccio.api.schemas.rules import (
    ApplyRulesResponse,
    CreateRuleRequest,
    RuleResponse,
    RulesResponse,
)
from traccio.core.logging import get_logger
from traccio.db.repositories import (
    create_rule,
    delete_rule,
    get_category,
    get_rule,
    list_all_transactions,
    list_rules,
    rule_exists,
    set_suggested_categories,
)
from traccio.db.session import get_session
from traccio.domain.models import Rule
from traccio.domain.rules import RuleError, normalize_rule_pattern
from traccio.services.categorization import evaluation_order, suggest_categories

logger = get_logger(__name__)

router = APIRouter()


def _load_rule(session: Session, *, user_id: UUID, rule_id: UUID) -> Rule:
    """Load a rule owned by the user, or raise ``404``.

    Scoping is enforced by :func:`~traccio.db.repositories.get_rule`, so
    naming another user's (or an unknown) rule is indistinguishable from "not
    found".
    """
    return load_or_404(
        lambda: get_rule(session, user_id=user_id, rule_id=rule_id),
        detail="unknown rule",
    )


@router.post("/rules", response_model=RuleResponse, status_code=status.HTTP_201_CREATED)
def create_rule_endpoint(
    body: CreateRuleRequest,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> RuleResponse:
    """Create a rule.

    Scoped to the current user. A ``404`` if the target category is unknown or
    not the caller's; a ``409`` if the (normalized) ``(match_kind, pattern)``
    collides with one of the user's existing rules; a ``422`` if the pattern is
    blank or too long.

    Parameters
    ----------
    body : CreateRuleRequest
        The target category, predicate, and pattern.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the rule belongs to.

    Returns
    -------
    RuleResponse
        The created rule.
    """
    category = get_category(session, user_id=user_id, category_id=body.category_id)
    if category is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="unknown category")

    try:
        pattern = normalize_rule_pattern(body.pattern)
    except RuleError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=exc.reason
        ) from exc

    if rule_exists(session, user_id=user_id, match_kind=body.match_kind, pattern=pattern):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="rule_already_exists")

    rule = Rule(
        user_id=user_id, category_id=body.category_id, match_kind=body.match_kind, pattern=pattern
    )
    created = create_rule(session, rule=rule)
    session.commit()
    logger.info("rules.create", rule_id=str(created.id))
    return RuleResponse.from_domain(created)


@router.get("/rules", response_model=RulesResponse)
def rules(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> RulesResponse:
    """List the current user's rules, in evaluation order.

    The order they are shown in is the order they actually fire in (see
    :func:`~traccio.services.categorization.evaluation_order`).

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose rules to return.

    Returns
    -------
    RulesResponse
        The user's rules, most specific first (empty if none).
    """
    found = evaluation_order(list_rules(session, user_id))
    logger.info("rules.list", count=len(found))
    return RulesResponse(rules=[RuleResponse.from_domain(r) for r in found])


@router.delete("/rules/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_rule(
    rule_id: UUID,
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> None:
    """Delete a rule.

    A ``404`` if the rule is unknown or not the caller's. Deleting a rule does
    not clear any suggestion it previously produced — the next ``POST
    /rules/apply`` recomputes from scratch and clears it then.

    Parameters
    ----------
    rule_id : UUID
        The rule to delete.
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user the rule belongs to.
    """
    _load_rule(session, user_id=user_id, rule_id=rule_id)
    delete_rule(session, user_id=user_id, rule_id=rule_id)
    session.commit()
    logger.info("rules.delete", rule_id=str(rule_id))


@router.post("/rules/apply", response_model=ApplyRulesResponse)
def apply_rules(
    session: Annotated[Session, Depends(get_session)],
    user_id: Annotated[UUID, Depends(current_user_id)],
) -> ApplyRulesResponse:
    """Recompute every rule against the user's transactions.

    A full, idempotent recompute — not incremental: every transaction's
    ``suggested_category_id`` is set to the first matching rule's category, or
    cleared to ``None`` if no rule matches (see
    :func:`~traccio.services.categorization.suggest_categories`). Never touches
    ``confirmed_category_id``. Detection only suggests
    (``docs/architecture.md``); a transaction with a confirmed category still
    receives a suggestion underneath it.

    Parameters
    ----------
    session : Session
        Request-scoped database session.
    user_id : UUID
        The user whose rules and transactions to use.

    Returns
    -------
    ApplyRulesResponse
        How many rules were evaluated, and how many transactions were matched
        vs. cleared.
    """
    all_rules = list_rules(session, user_id)
    all_transactions = list_all_transactions(session, user_id)
    suggestions = suggest_categories(all_transactions, all_rules)

    assignments = {s.transaction_id: s.category_id for s in suggestions}
    matched, cleared = set_suggested_categories(session, user_id=user_id, assignments=assignments)
    session.commit()
    logger.info("rules.apply", rules_applied=len(all_rules), matched=matched, cleared=cleared)
    return ApplyRulesResponse(rules_applied=len(all_rules), matched=matched, cleared=cleared)
