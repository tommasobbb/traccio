"""Pure normalization of Enable Banking transaction entries into domain objects.

Kept apart from :mod:`~traccio.providers.enable_banking.provider` (which owns the
HTTP orchestration — uid resolution and paging) so the field-by-field mapping
stays a set of small, pure, network-free functions that are exhaustively
testable on their own.

These functions are the anti-corruption boundary for the three transaction-level
normalization duties every adapter owes (``docs/architecture.md``,
``docs/domain.md``):

- **Sign.** Enable Banking sends an unsigned ``amount`` plus a
  ``credit_debit_indicator`` (ISO 20022 ``CRDT``/``DBIT``). We store negative for
  money leaving the account, positive for money arriving — for *every* account
  kind, cards included. The indicator is authoritative; any per-bank card
  inversion is finalized in one seam (:func:`_normalize_sign`).
- **Stable identity.** Prefer the bank's ``entry_reference``; when absent, derive
  a hash and record which :class:`~traccio.domain.enums.KeyStrategy` produced the
  key, so fallback-keyed rows can be treated as lower-confidence.
- **Dates.** ``booked_at`` (when the bank settled it, absent while pending) is
  distinct from ``value_date`` (when it affects the balance).

Money is integer minor units, never float: the decimal-string ``amount`` is
parsed with :class:`decimal.Decimal` and scaled, never through ``float`` (root
``CLAUDE.md``). Errors raise a value-free
:class:`~traccio.providers.base.ProviderError` (``.claude/rules/data-safety.md``):
no amount, description, or counterparty ever enters a message.
"""

import hashlib
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from pydantic import ValidationError

from traccio.domain import Account, AccountKind, Transaction
from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.money import Money
from traccio.providers.base import ProviderError

# ISO 20022 credit/debit indicators. DBIT = money out (stored negative),
# CRDT = money in (stored positive). Any other value fails loud.
_DEBIT = "DBIT"
_CREDIT = "CRDT"
# Enable Banking transaction status -> our settlement model. RJCT (rejected or
# reversed, terminal like booked) was surfaced by the first PayPal sync
# (docs/openbanking.md). INFO and other codes are still refused rather than
# coerced, so an unmodelled status surfaces on its first real sync instead of
# masquerading as a booked movement.
_STATUS_MAP = {
    "BOOK": TransactionStatus.BOOKED,
    "PDNG": TransactionStatus.PENDING,
    "RJCT": TransactionStatus.REJECTED,
}
# Minor units per major unit for the currencies M1 targets (EUR, GBP, …, all
# two-decimal). A currency with a different exponent (JPY 0, BHD 3) would need
# its own scale; until one is actually synced we require the amount to have no
# more than two decimals and fail loud otherwise (see docs/openbanking.md).
_MINOR_UNIT_SCALE = Decimal(100)
# Separator between hash components: a control char that cannot appear in the
# joined fields, so distinct inputs cannot collide by concatenation.
_HASH_SEP = "\x1f"


def to_transaction(raw: dict[str, Any], *, account: Account) -> Transaction:
    """Normalize one Enable Banking transaction entry into a domain object.

    The transaction carries its *own* currency (a card purchase abroad settles in
    a different one than the account), so the amount currency is taken from the
    entry, not from ``account``.

    Parameters
    ----------
    raw : dict
        A single entry from the ``transactions`` array of
        :meth:`~traccio.providers.enable_banking.client.EnableBankingClient.get_account_transactions`.
    account : Account
        The persisted account this movement belongs to. Its ``id`` is stable
        across syncs and feeds both ``account_id`` and the derived-hash key.

    Returns
    -------
    Transaction
        A fully normalized, deduplication-ready domain transaction.

    Raises
    ------
    ProviderError
        If a required field is missing or malformed, the amount is not
        expressible in whole minor units, or the status/indicator is unknown.
        The message is value-free (never echoes the payload).
    """
    try:
        amount = raw["transaction_amount"]
        amount_raw = amount["amount"]
        currency = amount["currency"]
        indicator = raw["credit_debit_indicator"]
        status_raw = raw["status"]
    except (KeyError, TypeError) as exc:
        raise ProviderError("Enable Banking transaction is malformed") from exc

    cents = _amount_to_cents(amount_raw, indicator=indicator, kind=account.kind)
    status = _map_status(status_raw)
    booked_at = _parse_date(raw.get("booking_date"))
    value_date = _parse_date(raw.get("value_date"))
    description = _remittance_to_description(raw.get("remittance_information"))
    entry_reference = raw.get("entry_reference")
    stable_key, key_strategy = _derive_stable_key(
        entry_reference,
        account_id=str(account.id),
        value_date=value_date,
        amount=cents,
        currency=currency,
        description=description,
    )

    try:
        return Transaction(
            user_id=account.user_id,
            account_id=account.id,
            money=Money(amount=cents, currency=currency),
            booked_at=booked_at,
            value_date=value_date,
            description=description,
            status=status,
            entry_reference=entry_reference,
            stable_key=stable_key,
            key_strategy=key_strategy,
        )
    except ValidationError as exc:
        # A field of the wrong shape (e.g. a non-ISO currency) is a malformed
        # payload; keep the message value-free.
        raise ProviderError("Enable Banking transaction is malformed") from exc


def _amount_to_cents(amount_raw: object, *, indicator: str, kind: AccountKind) -> int:
    """Convert a decimal-string amount + indicator into signed integer minor units.

    The magnitude comes from :class:`decimal.Decimal` (never ``float``); the sign
    comes from ``indicator`` (``DBIT`` negative, ``CRDT`` positive). An amount
    with more precision than the two-decimal minor unit — i.e. one that would not
    be a whole number of cents — is refused rather than rounded.
    """
    try:
        scaled = Decimal(amount_raw) * _MINOR_UNIT_SCALE  # type: ignore[arg-type]
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ProviderError("Enable Banking transaction amount is not a valid number") from exc
    if scaled != scaled.to_integral_value():
        raise ProviderError("Enable Banking transaction amount is not a whole number of cents")

    magnitude = abs(int(scaled))
    if indicator == _DEBIT:
        signed = -magnitude
    elif indicator == _CREDIT:
        signed = magnitude
    else:
        raise ProviderError("Enable Banking transaction has an unknown credit/debit indicator")
    return _normalize_sign(kind, signed)


def _normalize_sign(kind: AccountKind, cents: int) -> int:
    """Finalize the stored sign for an account kind.

    The single place a card-account sign inversion would be applied. Enable
    Banking normalizes to the account-holder's perspective, so the ISO
    ``credit_debit_indicator`` is already correct for current, savings, and card
    accounts alike, and this is the identity today. It stays the one documented
    seam for the duty (``docs/domain.md``: "a purchase is stored negative, for
    every account type"): if a specific bank is found to report card movements
    inverted, the per-bank branch is added here — and recorded in the per-bank
    findings — rather than scattered across call sites.
    """
    del kind  # no kind inverts under the current provider; see docstring.
    return cents


def _map_status(raw: object) -> TransactionStatus:
    """Map an Enable Banking status code to a :class:`TransactionStatus`."""
    status = _STATUS_MAP.get(raw) if isinstance(raw, str) else None
    if status is None:
        raise ProviderError("Enable Banking transaction has an unsupported status")
    return status


def _parse_date(raw: object) -> datetime | None:
    """Parse an ISO date/datetime into a tz-aware UTC datetime, or ``None``.

    Enable Banking emits ISO-8601 (usually a bare ``YYYY-MM-DD``, which parses to
    midnight); a naive value is assumed UTC. Absent (``None``) stays ``None``.
    """
    if raw is None:
        return None
    if not isinstance(raw, str):
        raise ProviderError("Enable Banking transaction date is not a valid datetime")
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise ProviderError("Enable Banking transaction date is not a valid datetime") from exc
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)


def _remittance_to_description(raw: object) -> str:
    """Join the ``remittance_information`` lines into a raw description.

    Enable Banking gives an array of free-text lines (no clean merchant name — it
    does not enrich). They are preserved verbatim as ``description``; producing a
    cleaned ``display_description`` is separate, later work. Absent → empty.
    """
    if raw is None:
        return ""
    if not isinstance(raw, list):
        raise ProviderError("Enable Banking transaction remittance information is malformed")
    return " ".join(str(line) for line in raw)


def _derive_stable_key(
    entry_reference: str | None,
    *,
    account_id: str,
    value_date: datetime | None,
    amount: int,
    currency: str,
    description: str,
) -> tuple[str, KeyStrategy]:
    """Choose the deduplication key and record which strategy produced it.

    The bank's ``entry_reference`` is the reliable key when present (ISO 20022
    caps it well under the ``stable_key`` column width). Absent, the fallback is a
    SHA-256 over ``(account_id, value_date, amount, currency, description)`` — a
    64-char hex digest that fits the column and is deterministic across syncs, but
    lower-confidence since near-identical entries collide (two identical coffees
    on the same day). The chosen :class:`KeyStrategy` travels with the key so that
    downstream deduplication can treat the two cases differently.
    """
    if entry_reference:
        return entry_reference, KeyStrategy.ENTRY_REFERENCE
    components = [
        account_id,
        value_date.isoformat() if value_date is not None else "",
        str(amount),
        currency,
        description,
    ]
    digest = hashlib.sha256(_HASH_SEP.join(components).encode("utf-8")).hexdigest()
    return digest, KeyStrategy.DERIVED_HASH
