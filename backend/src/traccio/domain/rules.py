"""Pure rule logic: pattern validation and the single-rule match predicate.

A :class:`~traccio.domain.models.Rule` is a user-defined mapping from a
transaction pattern to a :class:`~traccio.domain.models.Category`
(``docs/domain.md`` §Rule). This module holds only the pure derivations — no
I/O, imports only ``domain`` — so they are testable without a database and
reused by the API layer and by :mod:`traccio.services.categorization`.

Scope (2026-08-21): pattern validation and the ``rule_matches`` predicate only.
Evaluating a whole rule set against a whole transaction pool (specificity
ordering, first-match resolution) lives in
:mod:`traccio.services.categorization` — the same split as
``domain/categories.py`` (single-transaction rules) vs ``services/transfers.py``
(matching over a pool).
"""

from traccio.domain.enums import RuleMatchKind
from traccio.domain.models import Rule, Transaction

# Column width in ``db/models.py``; kept here as the single named constant so
# the API layer and the migration agree on one number, never a literal at the
# call site.
MAX_RULE_PATTERN_LENGTH = 255

# Stable, value-free reason codes for an invalid rule pattern. Exposed so the
# API layer can map a rejection to an HTTP status without parsing a message.
REASON_BLANK_PATTERN = "blank_pattern"
REASON_PATTERN_TOO_LONG = "pattern_too_long"


class RuleError(ValueError):
    """A rule pattern is not well-formed.

    Raised by :func:`normalize_rule_pattern`. Carries a stable, value-free
    ``reason`` (one of the module ``REASON_*`` constants) so the API layer can
    map it to an HTTP status without inspecting the message. The offending
    pattern is never included — it is merchant/counterparty text, exactly what
    ``.claude/rules/data-safety.md`` forbids in an error message.

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid rule pattern: {reason}")
        self.reason = reason


def normalize_rule_pattern(pattern: str) -> str:
    """Strip and validate a user-supplied rule pattern.

    Parameters
    ----------
    pattern : str
        The raw pattern as typed by the user.

    Returns
    -------
    str
        The stripped pattern.

    Raises
    ------
    RuleError
        If the pattern is empty after stripping (``reason`` is
        :data:`REASON_BLANK_PATTERN`) or exceeds
        :data:`MAX_RULE_PATTERN_LENGTH` (``reason`` is
        :data:`REASON_PATTERN_TOO_LONG`). The pattern itself is never included
        in the message.
    """
    stripped = pattern.strip()
    if not stripped:
        raise RuleError(REASON_BLANK_PATTERN)
    if len(stripped) > MAX_RULE_PATTERN_LENGTH:
        raise RuleError(REASON_PATTERN_TOO_LONG)
    return stripped


def rule_matches(rule: Rule, transaction: Transaction) -> bool:
    """Return whether ``rule`` matches ``transaction``.

    Matches against ``transaction.description`` — the raw bank text, never
    ``display_description`` (no code path populates it today; matching against
    it would silently change behaviour the day cleanup lands — see
    ``tasks/backlog.md``). Comparison is case-insensitive (casefolded) on both
    sides.

    Parameters
    ----------
    rule : Rule
        The rule to evaluate.
    transaction : Transaction
        The movement to match against.

    Returns
    -------
    bool
        ``True`` if ``rule.pattern`` matches ``transaction.description`` under
        ``rule.match_kind``.
    """
    description = transaction.description.casefold()
    pattern = rule.pattern.casefold()
    match rule.match_kind:
        case RuleMatchKind.CONTAINS:
            return pattern in description
        case RuleMatchKind.STARTS_WITH:
            return description.startswith(pattern)
        case RuleMatchKind.EQUALS:
            return description == pattern
