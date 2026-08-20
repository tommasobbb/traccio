"""The Enable Banking :class:`~traccio.providers.base.BankProvider` adapter.

This is the anti-corruption boundary: it composes an
:class:`~traccio.providers.enable_banking.client.EnableBankingClient` (which
speaks Enable Banking's HTTP shapes) and maps its raw payloads to the domain
DTOs the layers above ``providers/`` understand. Nothing here leaks a
provider-shaped dict upward.

Implements the full :class:`~traccio.providers.base.BankProvider` contract: the
consent handshake (``start_authorization`` / ``complete_authorization``), account
retrieval (``list_accounts``), and transaction retrieval (``fetch_transactions``,
whose field-by-field normalization lives in
:mod:`~traccio.providers.enable_banking.transactions`).

The adapter is **stateless**: it generates the anti-CSRF ``state`` and returns
it as the ``session_reference``; persisting the pairing between that reference
and the pending :class:`~traccio.domain.models.Connection` (so the callback can
be matched to it) is the caller's job, not the adapter's. Likewise it holds no
account-uid cache — ``fetch_transactions`` re-resolves the provider uid from the
stored account's stable ``identification_hash`` each call.

Data safety (``.claude/rules/data-safety.md``): never logs the SCA url (it embeds
``state``), the callback ``code``, the ``session_id`` credential, or any
transaction contents. Failures raise
:class:`~traccio.providers.base.ProviderError` with stable, value-free messages.
"""

import secrets
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from typing import Any, cast

from pydantic import ValidationError

from traccio.domain import Account, AccountKind, ConnectionStatus, Transaction
from traccio.providers.base import (
    AuthorizationResult,
    AuthorizationStart,
    BankProvider,
    ProviderAccount,
    ProviderError,
    SyncContext,
)
from traccio.providers.enable_banking.client import EnableBankingClient
from traccio.providers.enable_banking.transactions import to_transaction

_PROVIDER_NAME = "enable_banking"
# PSU type for M1: the account holder authorizing their own personal accounts.
_PSU_TYPE = "personal"
# Consent lifetime requested; the maximum most banks allow. The bank may grant
# less, so the response's valid_until is authoritative (see docs/openbanking.md).
_MAX_CONSENT_DAYS = 180
# ISO 20022 external cash-account-type -> our AccountKind. Only the kinds M1
# targets (personal current, savings, card) are mapped; any other value the bank
# reports (CASH, LOAN, OTHR) is refused rather than silently coerced, so an
# unmodelled account fails loudly instead of masquerading as a current account.
_CASH_ACCOUNT_TYPE_TO_KIND = {
    "CACC": AccountKind.CURRENT,
    "SVGS": AccountKind.SAVINGS,
    "CARD": AccountKind.CARD,
}


class EnableBankingProvider(BankProvider):
    """Enable Banking adapter, composing an :class:`EnableBankingClient`.

    Parameters
    ----------
    client : EnableBankingClient
        The authenticated HTTP client used for all provider calls.
    """

    def __init__(self, client: EnableBankingClient) -> None:
        self._client = client

    @property
    def name(self) -> str:
        return _PROVIDER_NAME

    def start_authorization(
        self, *, institution: str, country: str, redirect_url: str
    ) -> AuthorizationStart:
        state = secrets.token_urlsafe(32)
        valid_until = datetime.now(UTC) + timedelta(days=_MAX_CONSENT_DAYS)
        response = self._client.start_authorization(
            aspsp_name=institution,
            aspsp_country=country,
            redirect_url=redirect_url,
            state=state,
            access={"valid_until": valid_until.isoformat()},
            psu_type=_PSU_TYPE,
        )
        try:
            authorization_url = response["url"]
        except KeyError as exc:
            raise ProviderError("Enable Banking /auth response is missing 'url'") from exc
        return AuthorizationStart(authorization_url=authorization_url, session_reference=state)

    def complete_authorization(
        self, *, session_reference: str, callback_payload: Mapping[str, str]
    ) -> AuthorizationResult:
        if "error" in callback_payload:
            # Do not interpolate error/error_description — they can echo input.
            raise ProviderError("Enable Banking authorization callback returned an error")
        # Constant-time compare: the state is the anti-CSRF secret.
        callback_state = callback_payload.get("state", "")
        if not secrets.compare_digest(callback_state, session_reference):
            raise ProviderError("Enable Banking authorization callback state mismatch")
        code = callback_payload.get("code")
        if not code:
            raise ProviderError("Enable Banking authorization callback is missing 'code'")

        response = self._client.authorize_session(code=code)
        try:
            session_id = response["session_id"]
            valid_until_raw = response["access"]["valid_until"]
        except (KeyError, TypeError) as exc:
            raise ProviderError("Enable Banking /sessions response is malformed") from exc

        return AuthorizationResult(
            credentials=session_id,
            status=ConnectionStatus.ACTIVE,
            expires_at=_parse_valid_until(valid_until_raw),
        )

    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[ProviderAccount]:
        # context is threaded for the PSU-present headers a later slice will set on
        # the account calls; the client does not send them yet (see docs/openbanking.md).
        del context
        session = self._client.get_session(credentials)
        account_uids = session.get("accounts")
        if not isinstance(account_uids, list):
            raise ProviderError("Enable Banking /sessions response is missing 'accounts'")
        return [_to_provider_account(self._client.get_account_details(uid)) for uid in account_uids]

    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        # context is threaded for the PSU-present headers a later slice will set;
        # the client does not send them yet (see docs/openbanking.md), mirroring
        # list_accounts.
        del context
        account_uid = self._resolve_account_uid(credentials, account.identification_hash)
        date_from = since.date().isoformat()
        date_to = until.date().isoformat() if until is not None else None

        transactions: list[Transaction] = []
        continuation_key: str | None = None
        seen_keys: set[str] = set()
        while True:
            page = self._client.get_account_transactions(
                account_uid,
                date_from=date_from,
                date_to=date_to,
                continuation_key=continuation_key,
            )
            entries = page.get("transactions")
            if not isinstance(entries, list):
                raise ProviderError("Enable Banking transactions response is malformed")
            transactions.extend(to_transaction(entry, account=account) for entry in entries)

            continuation_key = page.get("continuation_key")
            if not continuation_key:
                break
            # Guard against a provider that loops the same page forever.
            if continuation_key in seen_keys:
                raise ProviderError("Enable Banking transactions paging did not terminate")
            seen_keys.add(continuation_key)
        return transactions

    def _resolve_account_uid(self, credentials: str, identification_hash: str) -> str:
        """Resolve the Enable Banking account UID for a stored account.

        The domain :class:`Account` carries the stable ``identification_hash`` but
        not the provider's session-scoped ``account_uid`` (the ``ProviderAccount``
        boundary deliberately drops it), so the uid is re-resolved here: list the
        session's uids and match on the ``identification_hash`` from each account's
        details. Stateless, at the cost of the extra detail calls — acceptable at
        the handful-of-accounts scale this runs at.
        """
        session = self._client.get_session(credentials)
        account_uids = session.get("accounts")
        if not isinstance(account_uids, list):
            raise ProviderError("Enable Banking /sessions response is missing 'accounts'")
        for uid in account_uids:
            details = self._client.get_account_details(uid)
            if details.get("identification_hash") == identification_hash:
                return cast(str, uid)
        raise ProviderError("Enable Banking session does not expose the requested account")


def _to_provider_account(details: Mapping[str, Any]) -> ProviderAccount:
    """Normalize an Enable Banking ``AccountResource`` into a :class:`ProviderAccount`.

    Enable Banking supplies a stable ``identification_hash`` (it matches an account
    across sessions and re-authorizations), so it is used directly as the adapter's
    stable identity — the raw IBAN never leaves the provider. The display name is
    the bank's proprietary ``product`` name, deliberately **not** the account-holder
    ``name`` field, which is personal data (``.claude/rules/data-safety.md``).

    Parameters
    ----------
    details : Mapping
        The raw ``AccountResource`` from
        :meth:`~traccio.providers.enable_banking.client.EnableBankingClient.get_account_details`.

    Returns
    -------
    ProviderAccount
        The provider-agnostic account.

    Raises
    ------
    ProviderError
        If a required field is absent or the account type is one this model does
        not represent. The message is value-free (never echoes the payload).
    """
    try:
        identification_hash = details["identification_hash"]
        cash_account_type = details["cash_account_type"]
        currency = details["currency"]
    except (KeyError, TypeError) as exc:
        raise ProviderError("Enable Banking account details are malformed") from exc

    kind = _CASH_ACCOUNT_TYPE_TO_KIND.get(cash_account_type)
    if kind is None:
        raise ProviderError("Enable Banking account has an unsupported cash_account_type")

    try:
        return ProviderAccount(
            identification_hash=identification_hash,
            kind=kind,
            currency=currency,
            name=details.get("product"),
        )
    except ValidationError as exc:
        # A field of the wrong type/shape (e.g. a non-ISO currency) is a
        # malformed payload; keep the message value-free.
        raise ProviderError("Enable Banking account details are malformed") from exc


def _parse_valid_until(raw: str) -> datetime:
    """Parse the provider's ``valid_until`` into a timezone-aware UTC datetime.

    Enable Banking emits ISO-8601; a naive value is assumed UTC. A value we
    cannot parse raises :class:`~traccio.providers.base.ProviderError` (value-free).
    """
    try:
        parsed = datetime.fromisoformat(raw)
    except (ValueError, TypeError) as exc:
        raise ProviderError("Enable Banking consent expiry is not a valid datetime") from exc
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)
