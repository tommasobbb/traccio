"""Pure category rules: name validation, the default tree, effective category.

A :class:`~traccio.domain.models.Category` is what kind of spending a
transaction represents. Two layers on ``Transaction`` (see ``docs/domain.md``):
``suggested_category_id``, written by the categorization engine and overwritten
freely on every re-run, and ``confirmed_category_id``, written only by explicit
user action and never by any automated process. This module holds only the pure
derivations — no I/O, imports only ``domain/`` — so they are testable without a
database and reused by the API layer.

Scope (2026-08-25, ADR 0018): categories now form a strict **two-level**
hierarchy — a root and, optionally, its direct children, never deeper — and
carry a colour and an optional icon (ADR 0017). Depth is enforced here, the one
place the rule can be checked without a database round trip; the DB cannot
express "at most two levels" portably.
"""

from typing import NamedTuple
from uuid import UUID

from traccio.domain.enums import CategoryIcon, PaletteColor
from traccio.domain.models import Category, Transaction

# Column width in ``db/models.py``; kept here as the single named constant so
# the API layer and the migration agree on one number, never a literal at the
# call site.
MAX_CATEGORY_NAME_LENGTH = 255


class DefaultCategory(NamedTuple):
    """One entry in :data:`DEFAULT_CATEGORY_TREE` — a root or a child.

    A plain ``NamedTuple`` rather than :class:`~traccio.domain.models.Category`
    itself: this is a *template*, with no ``id``/``user_id`` yet (those are
    minted per-user by :func:`default_categories`), and ``children`` has no
    counterpart on the real entity (a real ``Category`` carries a single
    ``parent_id``, not a nested list).

    Attributes
    ----------
    name : str
        The category's name.
    color : PaletteColor
        Its default colour.
    icon : CategoryIcon
        Its default icon.
    children : tuple[DefaultCategory, ...]
        Direct children, one level deep only — a child's own ``children`` is
        never populated, which is what keeps the tree's depth structurally
        obvious even before :func:`validate_parent` runs.
    """

    name: str
    color: PaletteColor
    icon: CategoryIcon
    children: tuple["DefaultCategory", ...] = ()


# The shared set every user is seeded with (see :func:`default_categories`).
# Root names are byte-identical to the flat set this replaces (2026-08-21) —
# that identity is what lets the migration backfill existing rows by name.
# Children are a first, deliberately small, sensible set — not exhaustive
# coverage of every root — the user adds their own from here.
DEFAULT_CATEGORY_TREE: tuple[DefaultCategory, ...] = (
    DefaultCategory("Groceries", PaletteColor.GREEN, CategoryIcon.GROCERIES),
    DefaultCategory(
        "Dining out",
        PaletteColor.ORANGE,
        CategoryIcon.DINING,
        children=(
            DefaultCategory("Coffee", PaletteColor.ORANGE, CategoryIcon.COFFEE),
            DefaultCategory("Takeout", PaletteColor.ORANGE, CategoryIcon.TAKEOUT),
        ),
    ),
    DefaultCategory(
        "Transport",
        PaletteColor.BLUE,
        CategoryIcon.TRANSPORT,
        children=(
            DefaultCategory("Fuel", PaletteColor.BLUE, CategoryIcon.FUEL),
            DefaultCategory("Public transport", PaletteColor.BLUE, CategoryIcon.PUBLIC_TRANSPORT),
        ),
    ),
    DefaultCategory(
        "Housing",
        PaletteColor.INDIGO,
        CategoryIcon.HOUSING,
        children=(
            DefaultCategory("Rent", PaletteColor.INDIGO, CategoryIcon.RENT),
            DefaultCategory("Maintenance", PaletteColor.INDIGO, CategoryIcon.MAINTENANCE),
        ),
    ),
    DefaultCategory("Utilities", PaletteColor.AMBER, CategoryIcon.UTILITIES),
    DefaultCategory("Health", PaletteColor.RED, CategoryIcon.HEALTH),
    DefaultCategory(
        "Shopping",
        PaletteColor.PINK,
        CategoryIcon.SHOPPING,
        children=(
            DefaultCategory("Clothing", PaletteColor.PINK, CategoryIcon.CLOTHING),
            DefaultCategory("Electronics", PaletteColor.PINK, CategoryIcon.ELECTRONICS),
        ),
    ),
    DefaultCategory(
        "Entertainment",
        PaletteColor.PURPLE,
        CategoryIcon.ENTERTAINMENT,
        children=(
            DefaultCategory("Streaming", PaletteColor.PURPLE, CategoryIcon.STREAMING),
            DefaultCategory("Movies", PaletteColor.PURPLE, CategoryIcon.MOVIES),
        ),
    ),
    DefaultCategory("Travel", PaletteColor.TEAL, CategoryIcon.TRAVEL),
    DefaultCategory("Subscriptions", PaletteColor.SLATE, CategoryIcon.SUBSCRIPTIONS),
    DefaultCategory("Fees", PaletteColor.SLATE, CategoryIcon.FEES),
    DefaultCategory("Income", PaletteColor.GREEN, CategoryIcon.INCOME),
    DefaultCategory("Other", PaletteColor.SLATE, CategoryIcon.OTHER),
)

# Stable, value-free reason codes for an invalid category name or hierarchy
# move. Exposed so the API layer can map a rejection to an HTTP status
# without parsing a message.
REASON_BLANK_NAME = "blank_name"
REASON_NAME_TOO_LONG = "name_too_long"
REASON_DEPTH_EXCEEDED = "category_depth_exceeded"
REASON_SELF_PARENT = "category_self_parent"


class CategoryError(ValueError):
    """A category name or hierarchy placement is not well-formed.

    Raised by :func:`normalize_category_name` and :func:`validate_parent`.
    Carries a stable, value-free ``reason`` (one of the module ``REASON_*``
    constants) so the API layer can map it to an HTTP status without
    inspecting the message. The offending name is never included (see
    ``.claude/rules/data-safety.md`` — it is user-typed data, not a financial
    value, but the same discipline applies).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid category: {reason}")
        self.reason = reason


def normalize_category_name(name: str) -> str:
    """Strip and validate a user-supplied category name.

    Parameters
    ----------
    name : str
        The raw name as typed by the user.

    Returns
    -------
    str
        The stripped name.

    Raises
    ------
    CategoryError
        If the name is empty after stripping (``reason`` is
        :data:`REASON_BLANK_NAME`) or exceeds
        :data:`MAX_CATEGORY_NAME_LENGTH` (``reason`` is
        :data:`REASON_NAME_TOO_LONG`). The name itself is never included in the
        message.
    """
    stripped = name.strip()
    if not stripped:
        raise CategoryError(REASON_BLANK_NAME)
    if len(stripped) > MAX_CATEGORY_NAME_LENGTH:
        raise CategoryError(REASON_NAME_TOO_LONG)
    return stripped


def validate_parent(
    *, category_id: UUID | None, parent_id: UUID | None, parent_parent_id: UUID | None
) -> None:
    """Check a proposed parent against the two-level depth rule.

    The one place the "at most two levels" rule is enforced — the database
    cannot express it portably, so every create and every move goes through
    this before touching a row.

    Parameters
    ----------
    category_id : UUID or None
        The category being placed. ``None`` when creating a brand-new
        category (there is no id yet, so it cannot equal its own parent);
        set to the real id when moving an existing one.
    parent_id : UUID or None
        The proposed parent, or ``None`` for "make this a root" — always
        valid, and this function returns immediately.
    parent_parent_id : UUID or None
        The proposed parent's *own* parent id, as already stored. Non-``None``
        means the proposed parent is itself a child, which would make
        ``category_id`` a third level.

    Raises
    ------
    CategoryError
        :data:`REASON_SELF_PARENT` if ``parent_id == category_id``;
        :data:`REASON_DEPTH_EXCEEDED` if the proposed parent is itself a
        child.
    """
    if parent_id is None:
        return
    if category_id is not None and parent_id == category_id:
        raise CategoryError(REASON_SELF_PARENT)
    if parent_parent_id is not None:
        raise CategoryError(REASON_DEPTH_EXCEEDED)


def default_child_color(parent_color: PaletteColor) -> PaletteColor:
    """Return the colour a new child should default to.

    The single place this default lives: today a child simply inherits its
    parent's colour, but keeping this as a named function (rather than
    inlining ``parent.color`` at the call site) means a future, slightly
    different rule — a muted variant, say — changes in one place.

    Parameters
    ----------
    parent_color : PaletteColor
        The parent category's colour.

    Returns
    -------
    PaletteColor
        The child's default colour.
    """
    return parent_color


def effective_category(transaction: Transaction) -> UUID | None:
    """Return the category id that actually applies to ``transaction``.

    The confirmed category wins whenever it is set; only in its absence does the
    suggested one apply. This is the single place this fallback rule exists —
    sibling to :func:`~traccio.domain.effective_amount.effective_amount` — so the
    API layer and, later, any dashboard or budget total never re-implement it.
    Unchanged by the two-level hierarchy: a transaction's category id may name
    a root or a child, and this function does not care which.

    Parameters
    ----------
    transaction : Transaction
        The movement to derive from.

    Returns
    -------
    UUID or None
        ``transaction.confirmed_category_id`` if set, else
        ``transaction.suggested_category_id``, else ``None`` when the
        transaction is not categorized at all.
    """
    if transaction.confirmed_category_id is not None:
        return transaction.confirmed_category_id
    return transaction.suggested_category_id


def default_categories(user_id: UUID) -> list[Category]:
    """Build the shared default category tree for one user.

    Pure construction — no I/O — so the seed set is testable without a database;
    :func:`traccio.db.repositories.seed_default_categories` is the only caller
    that persists the result. Each root's id is minted before its children are
    built, so their ``parent_id`` values are already correct on return — the
    caller does not need a second pass to wire them up.

    Parameters
    ----------
    user_id : UUID
        The user to seed.

    Returns
    -------
    list[Category]
        One :class:`~traccio.domain.models.Category` per
        :data:`DEFAULT_CATEGORY_TREE` root, immediately followed by its
        children (if any), owned by ``user_id``.
    """
    categories: list[Category] = []
    for root_def in DEFAULT_CATEGORY_TREE:
        root = Category(
            user_id=user_id, name=root_def.name, color=root_def.color, icon=root_def.icon
        )
        categories.append(root)
        for child_def in root_def.children:
            categories.append(
                Category(
                    user_id=user_id,
                    name=child_def.name,
                    parent_id=root.id,
                    color=child_def.color,
                    icon=child_def.icon,
                )
            )
    return categories
