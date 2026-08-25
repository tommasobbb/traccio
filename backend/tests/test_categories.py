"""Tests for the pure category rules (``domain/categories``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented names) — see ``.claude/rules/data-safety.md``.
"""

from uuid import UUID, uuid4

import pytest

from traccio.domain import KeyStrategy, Money, Transaction, TransactionStatus, default_categories
from traccio.domain.categories import (
    DEFAULT_CATEGORY_TREE,
    MAX_CATEGORY_NAME_LENGTH,
    REASON_BLANK_NAME,
    REASON_DEPTH_EXCEEDED,
    REASON_NAME_TOO_LONG,
    REASON_SELF_PARENT,
    CategoryError,
    default_child_color,
    effective_category,
    normalize_category_name,
    validate_parent,
)
from traccio.domain.enums import PaletteColor


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
    expected_count = len(DEFAULT_CATEGORY_TREE) + sum(
        len(root.children) for root in DEFAULT_CATEGORY_TREE
    )
    assert len(categories) == expected_count
    assert all(category.user_id == user_id for category in categories)
    names = [category.name for category in categories]
    assert len(names) == len(set(names))


def test_default_categories_has_all_thirteen_roots() -> None:
    """The 13 root names survive byte-identical (the migration backfill key)."""
    user_id = uuid4()
    categories = default_categories(user_id)
    root_names = {category.name for category in categories if category.parent_id is None}
    assert root_names == {
        "Groceries",
        "Dining out",
        "Transport",
        "Housing",
        "Utilities",
        "Health",
        "Shopping",
        "Entertainment",
        "Travel",
        "Subscriptions",
        "Fees",
        "Income",
        "Other",
    }


def test_default_categories_children_carry_their_roots_id() -> None:
    """Every child's parent_id resolves to a real root already in the list."""
    categories = default_categories(uuid4())
    root_ids = {category.id for category in categories if category.parent_id is None}
    children = [category for category in categories if category.parent_id is not None]
    assert children, "expected at least one default child category"
    assert all(child.parent_id in root_ids for child in children)


def test_validate_parent_allows_no_parent() -> None:
    """A `None` parent (a root) never raises, regardless of the other ids."""
    validate_parent(category_id=uuid4(), parent_id=None, parent_parent_id=uuid4())


def test_validate_parent_allows_a_root_parent() -> None:
    """Nesting under a genuine root (no parent of its own) is fine."""
    validate_parent(category_id=uuid4(), parent_id=uuid4(), parent_parent_id=None)


def test_validate_parent_rejects_self_parent() -> None:
    category_id = uuid4()
    with pytest.raises(CategoryError) as excinfo:
        validate_parent(category_id=category_id, parent_id=category_id, parent_parent_id=None)
    assert excinfo.value.reason == REASON_SELF_PARENT


def test_validate_parent_rejects_a_third_level() -> None:
    """A parent that is itself a child would make this a grandchild."""
    with pytest.raises(CategoryError) as excinfo:
        validate_parent(category_id=uuid4(), parent_id=uuid4(), parent_parent_id=uuid4())
    assert excinfo.value.reason == REASON_DEPTH_EXCEEDED


def test_validate_parent_on_create_has_no_self_parent_case() -> None:
    """category_id=None (a brand-new category) can never equal parent_id."""
    validate_parent(category_id=None, parent_id=uuid4(), parent_parent_id=None)


def test_default_child_color_inherits_the_parent() -> None:
    assert default_child_color(PaletteColor.TEAL) is PaletteColor.TEAL
