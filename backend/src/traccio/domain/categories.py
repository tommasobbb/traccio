"""Pure category rules: name validation, the default set, effective category.

A :class:`~traccio.domain.models.Category` is what kind of spending a
transaction represents. Two layers on ``Transaction`` (see ``docs/domain.md``):
``suggested_category_id``, written by the categorization engine and overwritten
freely on every re-run, and ``confirmed_category_id``, written only by explicit
user action and never by any automated process. This module holds only the pure
derivations — no I/O, imports only ``domain/`` — so they are testable without a
database and reused by the API layer.

Scope (2026-08-21): this slice is categories foundations — the entity, its
default set, and the effective-category fallback. The rules engine that *writes*
``suggested_category_id`` is a later slice (see ``tasks/backlog.md`` §M2); no
function here writes anything.
"""

from uuid import UUID

from traccio.domain.models import Category, Transaction

# Column width in ``db/models.py``; kept here as the single named constant so
# the API layer and the migration agree on one number, never a literal at the
# call site.
MAX_CATEGORY_NAME_LENGTH = 255

# The shared set every user is seeded with (see :func:`default_categories`).
# Deliberately flat and un-opinionated: no income/spending flag (that is
# already carried by the *sign* of ``effective_amount`` — a second flag would be
# a second, desynchronisable source of truth) and no hierarchy (YAGNI until a
# real need for nesting shows up).
DEFAULT_CATEGORY_NAMES: tuple[str, ...] = (
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
)

# Stable, value-free reason codes for an invalid category name. Exposed so the
# API layer can map a rejection to an HTTP status without parsing a message.
REASON_BLANK_NAME = "blank_name"
REASON_NAME_TOO_LONG = "name_too_long"


class CategoryError(ValueError):
    """A category name is not well-formed.

    Raised by :func:`normalize_category_name`. Carries a stable, value-free
    ``reason`` (one of the module ``REASON_*`` constants) so the API layer can
    map it to an HTTP status without inspecting the message. The offending name
    is never included (see ``.claude/rules/data-safety.md`` — it is user-typed
    data, not a financial value, but the same discipline applies).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid category name: {reason}")
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


def effective_category(transaction: Transaction) -> UUID | None:
    """Return the category id that actually applies to ``transaction``.

    The confirmed category wins whenever it is set; only in its absence does the
    suggested one apply. This is the single place this fallback rule exists —
    sibling to :func:`~traccio.domain.effective_amount.effective_amount` — so the
    API layer and, later, any dashboard or budget total never re-implement it.

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
    """Build the shared default category set for one user.

    Pure construction — no I/O — so the seed set is testable without a database;
    :func:`traccio.db.repositories.seed_default_categories` is the only caller
    that persists the result.

    Parameters
    ----------
    user_id : UUID
        The user to seed.

    Returns
    -------
    list[Category]
        One :class:`~traccio.domain.models.Category` per
        :data:`DEFAULT_CATEGORY_NAMES` entry, owned by ``user_id``.
    """
    return [Category(user_id=user_id, name=name) for name in DEFAULT_CATEGORY_NAMES]
