"""Tests for the pure search helpers (``domain/search``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(invented merchant text) — see ``.claude/rules/data-safety.md``.
"""

from traccio.domain.search import escape_like, normalize_search_term


def test_normalize_search_term_strips_surrounding_whitespace() -> None:
    assert normalize_search_term("  esselunga  ") == "esselunga"


def test_normalize_search_term_none_stays_none() -> None:
    assert normalize_search_term(None) is None


def test_normalize_search_term_blank_becomes_none() -> None:
    assert normalize_search_term("   ") is None


def test_normalize_search_term_does_not_truncate() -> None:
    long_term = "x" * 500
    assert normalize_search_term(long_term) == long_term


def test_escape_like_escapes_percent() -> None:
    assert escape_like("50%") == "50\\%"


def test_escape_like_escapes_underscore() -> None:
    assert escape_like("a_b") == "a\\_b"


def test_escape_like_escapes_backslash_first() -> None:
    # Escaping the backslash before the wildcards keeps a literal "\%" (an
    # already-escaped percent in the input) from becoming a real wildcard.
    assert escape_like("\\%") == "\\\\\\%"


def test_escape_like_leaves_plain_text_unchanged() -> None:
    assert escape_like("esselunga") == "esselunga"
