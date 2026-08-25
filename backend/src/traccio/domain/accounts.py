"""Pure account rules: alias validation and the display-name fallback.

A user may set an ``alias`` on an :class:`~traccio.domain.models.Account` to
tell otherwise-identical accounts apart (ADR 0017) — ``name`` alone is the
provider's own product name (e.g. "Conto corrente"), which several accounts at
the same bank often share, and is overwritten on every sync
(:func:`~traccio.db.repositories.upsert_account`). This module holds the one
pure derivation of what to actually display, plus alias validation — no I/O,
imports only ``domain/``, so both are testable without a database and reused
by the API layer.
"""

from traccio.domain.models import Account

# Generous relative to a category name (255): an alias is free text the user
# chose, not a controlled vocabulary, and a longer cap costs nothing.
MAX_ACCOUNT_ALIAS_LENGTH = 255

# Stable, value-free reason codes for an invalid alias. Exposed so the API
# layer can map a rejection to an HTTP status without parsing a message.
REASON_BLANK_ALIAS = "blank_alias"
REASON_ALIAS_TOO_LONG = "alias_too_long"


class AccountError(ValueError):
    """An account alias is not well-formed.

    Raised by :func:`normalize_account_alias`. Carries a stable, value-free
    ``reason`` (one of the module ``REASON_*`` constants) so the API layer can
    map it to an HTTP status without inspecting the message. The offending
    alias is never included (see ``.claude/rules/data-safety.md`` — it is
    user-typed data, not a financial value, but the same discipline applies).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid account alias: {reason}")
        self.reason = reason


def normalize_account_alias(alias: str | None) -> str | None:
    """Strip and validate a user-supplied account alias.

    ``None`` is a valid input and passes through unchanged — it is the
    explicit "clear the alias, fall back to the provider name" request, not an
    absent value (the request schema makes the field mandatory-but-nullable
    for exactly this reason).

    Parameters
    ----------
    alias : str or None
        The raw alias as typed by the user, or ``None`` to clear it.

    Returns
    -------
    str or None
        The stripped alias, or ``None`` if ``alias`` was ``None``.

    Raises
    ------
    AccountError
        If ``alias`` is not ``None`` but is empty after stripping (``reason``
        is :data:`REASON_BLANK_ALIAS` — clearing the alias is spelled with
        ``None``, not whitespace) or exceeds :data:`MAX_ACCOUNT_ALIAS_LENGTH`
        (``reason`` is :data:`REASON_ALIAS_TOO_LONG`). The alias itself is
        never included in the message.
    """
    if alias is None:
        return None
    stripped = alias.strip()
    if not stripped:
        raise AccountError(REASON_BLANK_ALIAS)
    if len(stripped) > MAX_ACCOUNT_ALIAS_LENGTH:
        raise AccountError(REASON_ALIAS_TOO_LONG)
    return stripped


def display_name(account: Account) -> str | None:
    """Return the one name that should actually be shown for ``account``.

    The single place this fallback lives (sibling to
    :func:`~traccio.domain.categories.effective_category`), so the API layer
    and every client surface agree — today the client has three different
    inconsistent fallback strings for a nameless account, one per screen.

    Parameters
    ----------
    account : Account
        The account to derive a display name for.

    Returns
    -------
    str or None
        ``account.alias`` if the user set one, else ``account.name`` (the
        provider's own name), else ``None`` when neither is set — the caller
        (the API response) decides the final placeholder text, since that is
        UI copy, not a domain fact.
    """
    return account.alias if account.alias is not None else account.name
