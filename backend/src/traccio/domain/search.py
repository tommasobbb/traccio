"""Pure helpers for free-text transaction search.

No I/O, imports nothing but the standard library, so both the normalization
and the ``LIKE`` escaping are testable without a database. Search text is
counterparty/merchant text (a transaction's description) — never logged, per
``.claude/rules/data-safety.md``.
"""

# Query-parameter length cap enforced by the API layer (``api/routers/
# transactions.py``); named here so the limit and its check live next to the
# rest of the search normalization, not as a bare literal at the call site.
MAX_SEARCH_TERM_LENGTH = 100


def normalize_search_term(raw: str | None) -> str | None:
    """Normalize a raw ``q`` query parameter.

    Parameters
    ----------
    raw : str or None
        The query parameter as received, possibly ``None`` or blank.

    Returns
    -------
    str or None
        The stripped term, or ``None`` if absent or blank once stripped.
        Never truncated — a term longer than :data:`MAX_SEARCH_TERM_LENGTH` is
        the caller's job to reject, not this function's job to silently cut.
    """
    if raw is None:
        return None
    stripped = raw.strip()
    return stripped or None


def escape_like(term: str) -> str:
    """Escape a search term for use in a SQL ``LIKE`` pattern.

    Escapes the backslash first, then the two ``LIKE`` wildcards, so a term
    containing a literal ``%`` or ``_`` (e.g. "50%") matches only that literal
    text rather than acting as a wildcard.

    Parameters
    ----------
    term : str
        The raw term to embed in a ``LIKE`` pattern.

    Returns
    -------
    str
        The term with ``\\``, ``%``, and ``_`` escaped with a backslash. The
        caller is responsible for passing ``escape="\\\\"`` to ``LIKE`` and
        wrapping the result in ``%...%`` for a contains-match.
    """
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
