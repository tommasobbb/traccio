"""Tests for the pure rule logic (``domain/rules``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented patterns) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import KeyStrategy, Money, Transaction, TransactionStatus
from traccio.domain.enums import RuleMatchKind
from traccio.domain.models import Rule
from traccio.domain.rules import (
    MAX_RULE_PATTERN_LENGTH,
    REASON_BLANK_PATTERN,
    REASON_PATTERN_TOO_LONG,
    RuleError,
    normalize_rule_pattern,
    rule_matches,
)


def _tx(description: str = "TEST MERCHANT 01") -> Transaction:
    """Build a synthetic transaction with the given description."""
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-5000, currency="EUR"),
        description=description,
        status=TransactionStatus.BOOKED,
        stable_key=f"TX-{uuid4()}",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def _rule(match_kind: RuleMatchKind, pattern: str) -> Rule:
    return Rule(user_id=uuid4(), category_id=uuid4(), match_kind=match_kind, pattern=pattern)


def test_contains_matches_anywhere_in_the_description() -> None:
    rule = _rule(RuleMatchKind.CONTAINS, "MERCHANT")
    assert rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_contains_does_not_match_when_absent() -> None:
    rule = _rule(RuleMatchKind.CONTAINS, "ESSELUNGA")
    assert not rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_starts_with_matches_a_prefix() -> None:
    rule = _rule(RuleMatchKind.STARTS_WITH, "TEST")
    assert rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_starts_with_does_not_match_mid_string() -> None:
    rule = _rule(RuleMatchKind.STARTS_WITH, "MERCHANT")
    assert not rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_equals_matches_the_whole_description() -> None:
    rule = _rule(RuleMatchKind.EQUALS, "TEST MERCHANT 01")
    assert rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_equals_does_not_match_a_substring() -> None:
    rule = _rule(RuleMatchKind.EQUALS, "MERCHANT")
    assert not rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_matching_is_case_insensitive() -> None:
    rule = _rule(RuleMatchKind.CONTAINS, "merchant")
    assert rule_matches(rule, _tx("TEST MERCHANT 01"))


def test_blank_pattern_is_rejected() -> None:
    with pytest.raises(RuleError) as excinfo:
        normalize_rule_pattern("")
    assert excinfo.value.reason == REASON_BLANK_PATTERN


def test_whitespace_only_pattern_is_rejected() -> None:
    with pytest.raises(RuleError) as excinfo:
        normalize_rule_pattern("   ")
    assert excinfo.value.reason == REASON_BLANK_PATTERN


def test_pattern_is_stripped() -> None:
    assert normalize_rule_pattern("  ESSELUNGA  ") == "ESSELUNGA"


def test_overlong_pattern_is_rejected() -> None:
    with pytest.raises(RuleError) as excinfo:
        normalize_rule_pattern("x" * (MAX_RULE_PATTERN_LENGTH + 1))
    assert excinfo.value.reason == REASON_PATTERN_TOO_LONG


def test_pattern_at_max_length_is_accepted() -> None:
    pattern = "x" * MAX_RULE_PATTERN_LENGTH
    assert normalize_rule_pattern(pattern) == pattern


def test_error_message_never_contains_the_pattern() -> None:
    """The exception message is stable and value-free (data-safety)."""
    candidate = "TEST SENSITIVE MERCHANT 01" * 20  # deliberately over the limit
    with pytest.raises(RuleError) as excinfo:
        normalize_rule_pattern(candidate)
    assert candidate not in str(excinfo.value)
