"""Tests for the pure category rules (``domain/categories``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented names) — see ``.claude/rules/data-safety.md``.
"""

from uuid import UUID, uuid4

import pytest

from traccio.domain import KeyStrategy, Money, Transaction, TransactionStatus, default_categories
from traccio.domain.categories import (
    DEFAULT_CATEGORY_NAMES,
    MAX_CATEGORY_NAME_LENGTH,
    REASON_BLANK_NAME,
    REASON_NAME_TOO_LONG,
    CategoryError,
    effective_category,
    normalize_category_name,
)


def _tx(
    *,
    suggested_category_id: UUID | None = None,
    confirmed_category_id: UUID | None = None,
) -> Transaction:
    """Build a synthetic transaction with optional category ids."""
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-5000, currency="EUR"),
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key=f"TX-{uuid4()}",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        suggested_category_id=suggested_category_id,
        confirmed_category_id=confirmed_category_id,
    )


def test_confirmed_category_wins_over_suggested() -> None:
    """The confirmed category always takes precedence over the suggestion."""
    suggested = uuid4()
    confirmed = uuid4()
    transaction = _tx(suggested_category_id=suggested, confirmed_category_id=confirmed)
    assert effective_category(transaction) == confirmed


def test_falls_back_to_suggested_when_not_confirmed() -> None:
    """With no confirmation, the suggestion is what applies."""
    suggested = uuid4()
    transaction = _tx(suggested_category_id=suggested, confirmed_category_id=None)
    assert effective_category(transaction) == suggested


def test_uncategorized_transaction_has_no_effective_category() -> None:
    """Neither id set means no category applies at all."""
    transaction = _tx(suggested_category_id=None, confirmed_category_id=None)
    assert effective_category(transaction) is None


def test_blank_name_is_rejected() -> None:
    """An empty name is not a valid category name."""
    with pytest.raises(CategoryError) as excinfo:
        normalize_category_name("")
    assert excinfo.value.reason == REASON_BLANK_NAME


def test_whitespace_only_name_is_rejected() -> None:
    """A name that is only whitespace is blank after stripping."""
    with pytest.raises(CategoryError) as excinfo:
        normalize_category_name("   ")
    assert excinfo.value.reason == REASON_BLANK_NAME


def test_name_is_stripped() -> None:
    """Surrounding whitespace is removed, not treated as part of the name."""
    assert normalize_category_name("  Groceries  ") == "Groceries"


def test_overlong_name_is_rejected() -> None:
    """A name past the column width is rejected before it ever reaches the DB."""
    with pytest.raises(CategoryError) as excinfo:
        normalize_category_name("x" * (MAX_CATEGORY_NAME_LENGTH + 1))
    assert excinfo.value.reason == REASON_NAME_TOO_LONG


def test_name_at_max_length_is_accepted() -> None:
    """The boundary itself is valid, not just anything shorter."""
    name = "x" * MAX_CATEGORY_NAME_LENGTH
    assert normalize_category_name(name) == name


def test_error_message_never_contains_the_name() -> None:
    """The exception message is stable and value-free (data-safety)."""
    candidate = "TEST SENSITIVE NAME 01" * 20  # deliberately over the limit
    with pytest.raises(CategoryError) as excinfo:
        normalize_category_name(candidate)
    assert candidate not in str(excinfo.value)


def test_default_categories_are_user_scoped_and_uniquely_named() -> None:
    """The seed set belongs to the given user and has no duplicate names."""
    user_id = uuid4()
    categories = default_categories(user_id)
    assert len(categories) == len(DEFAULT_CATEGORY_NAMES)
    assert all(category.user_id == user_id for category in categories)
    names = [category.name for category in categories]
    assert len(names) == len(set(names))
