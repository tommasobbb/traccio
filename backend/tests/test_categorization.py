"""Tests for the pure categorization service (``services/categorization``).

Pure unit tests: no database, no network. Fixtures use synthetic values only —
see ``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from traccio.domain import KeyStrategy, Money, Transaction, TransactionStatus
from traccio.domain.enums import RuleMatchKind
from traccio.domain.models import Rule
from traccio.services.categorization import CategorySuggestion, evaluation_order, suggest_categories

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    description: str = "TEST MERCHANT 01", *, confirmed_category_id: UUID | None = None
) -> Transaction:
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-5000, currency="EUR"),
        description=description,
        status=TransactionStatus.BOOKED,
        stable_key=f"TX-{uuid4()}",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        confirmed_category_id=confirmed_category_id,
    )


def _rule(
    match_kind: RuleMatchKind,
    pattern: str,
    *,
    category_id: UUID | None = None,
    created_at: datetime = _DAY,
) -> Rule:
    return Rule(
        user_id=uuid4(),
        category_id=category_id or uuid4(),
        match_kind=match_kind,
        pattern=pattern,
        created_at=created_at,
    )


def test_no_rules_yields_no_suggestions() -> None:
    transaction = _tx()
    suggestions = suggest_categories([transaction], [])
    assert suggestions == [
        CategorySuggestion(transaction_id=transaction.id, category_id=None, rule_id=None)
    ]


def test_no_matching_rule_yields_none() -> None:
    transaction = _tx("TEST MERCHANT 01")
    rule = _rule(RuleMatchKind.CONTAINS, "ESSELUNGA")
    [suggestion] = suggest_categories([transaction], [rule])
    assert suggestion.category_id is None
    assert suggestion.rule_id is None


def test_matching_rule_suggests_its_category() -> None:
    category_id = uuid4()
    transaction = _tx("TEST MERCHANT 01")
    rule = _rule(RuleMatchKind.CONTAINS, "MERCHANT", category_id=category_id)
    [suggestion] = suggest_categories([transaction], [rule])
    assert suggestion.category_id == category_id
    assert suggestion.rule_id == rule.id


def test_longer_pattern_wins_over_a_shorter_one() -> None:
    transaction = _tx("AMAZON PRIME VIDEO")
    specific = _rule(RuleMatchKind.CONTAINS, "AMAZON PRIME", category_id=uuid4())
    general = _rule(RuleMatchKind.CONTAINS, "AMAZON", category_id=uuid4())
    [suggestion] = suggest_categories([transaction], [general, specific])
    assert suggestion.category_id == specific.category_id
    assert suggestion.rule_id == specific.id


def test_equal_length_patterns_break_tie_by_created_at() -> None:
    # Both patterns are the same length and both match; the earlier-created
    # rule should win.
    transaction = _tx("TEST XX MERCHANT 01")
    earlier = _rule(RuleMatchKind.CONTAINS, "XX", category_id=uuid4(), created_at=_DAY)
    later = _rule(
        RuleMatchKind.CONTAINS, "01", category_id=uuid4(), created_at=_DAY + timedelta(days=1)
    )
    [suggestion] = suggest_categories([transaction], [later, earlier])
    assert suggestion.rule_id == earlier.id


def test_apply_is_a_full_recompute_and_clears_stale_suggestions() -> None:
    """A rule set with no matches must still produce an explicit ``None``.

    That is what makes ``POST /rules/apply`` idempotent: a stale suggestion
    from a since-deleted rule is cleared on the next run, not left in place.
    """
    transaction = _tx("TEST MERCHANT 01")
    [suggestion] = suggest_categories([transaction], [])
    assert suggestion.category_id is None


def test_confirmed_transaction_still_receives_a_suggestion() -> None:
    """The suggestion layer is a pure function of (rules, transactions).

    It does not know about confirmation — ``effective_category`` is what makes
    the confirmed value win when both are present.
    """
    category_id = uuid4()
    transaction = _tx("TEST MERCHANT 01", confirmed_category_id=uuid4())
    rule = _rule(RuleMatchKind.CONTAINS, "MERCHANT", category_id=category_id)
    [suggestion] = suggest_categories([transaction], [rule])
    assert suggestion.category_id == category_id


def test_empty_transaction_pool_yields_no_suggestions() -> None:
    rule = _rule(RuleMatchKind.CONTAINS, "MERCHANT")
    assert suggest_categories([], [rule]) == []


def test_evaluation_order_ranks_longest_pattern_first() -> None:
    short = _rule(RuleMatchKind.CONTAINS, "AMAZON")
    long = _rule(RuleMatchKind.CONTAINS, "AMAZON PRIME")
    assert evaluation_order([short, long]) == [long, short]


def test_evaluation_order_breaks_ties_by_created_at_then_id() -> None:
    earlier = _rule(RuleMatchKind.CONTAINS, "XX", created_at=_DAY)
    later = _rule(RuleMatchKind.CONTAINS, "YY", created_at=_DAY + timedelta(days=1))
    assert evaluation_order([later, earlier]) == [earlier, later]
