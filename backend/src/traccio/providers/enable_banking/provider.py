"""The Enable Banking :class:`~traccio.providers.base.BankProvider` adapter.

This is the anti-corruption boundary: it composes an
:class:`~traccio.providers.enable_banking.client.EnableBankingClient` (which
speaks Enable Banking's HTTP shapes) and maps its raw payloads to the domain
DTOs the layers above ``providers/`` understand. Nothing here leaks a
provider-shaped dict upward.

Implements the full :class:`~traccio.providers.base.BankProvider` contract:
institution discovery (``list_institutions``), the consent handshake
(``start_authorization`` / ``complete_authorization``), account retrieval
(``list_accounts``), and transaction retrieval (``fetch_transactions``, whose
field-by-field normalization lives in
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
    Institution,
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

# PSU-present headers sent to the two data-retrieval calls, when both
# `EnableBankingProvider.send_psu_headers` and `SyncContext.psu_present` are
# true (ADR 0011). Deliberately partial: the full documented set is
# `Psu-Ip-Address`, `Psu-User-Agent`, `Psu-Referer`, `Psu-Accept`,
# `Psu-Accept-Charset`, `Psu-Accept-Encoding`, `Psu-Accept-language`,
# `Psu-Geo-Location` (docs/openbanking.md). This codebase has no honest value
# for three of them in a headless backend: `Psu-Ip-Address` and
# `Psu-Geo-Location` need a real device, which does not reach this backend
# yet (`tasks/backlog.md` — the client only reaches localhost); `Psu-Referer`
# names a browser referring page, which has no equivalent for a server-to-
# server call. Fabricating any of the three would be worse than omitting
# them. Enable Banking's header set is all-or-nothing per the bank's own
# `required_psu_headers` (not fetched anywhere in this codebase), so even
# with the flag on, a bank whose required set includes one of the three
# omitted headers still refuses with `PSU_HEADER_NOT_PROVIDED`. This is a
# deliberately incomplete implementation, staged for the day client
# reachability or per-ASPSP header requirements are solved — see ADR 0011.
_PSU_HEADERS = {
    "Psu-User-Agent": "Traccio/1.0",
    "Psu-Accept": "application/json",
    "Psu-Accept-Charset": "utf-8",
    "Psu-Accept-Encoding": "identity",
    "Psu-Accept-language": "en",
}
# ISO 20022 external cash-account-type -> our AccountKind. The kinds M1 targets
# (personal current, savings, card) plus OTHR, which banks use for a
# currency-agnostic wallet such as PayPal (mapped to WALLET; the account may also
# report currency='XXX', which validates as an ISO 4217 code and is stored as-is
# because the per-transaction currency is authoritative). Any other value the
# bank reports (e.g. CASH, LOAN) is refused rather than silently coerced, so an
# unmodelled account fails loudly instead of masquerading as a current account.
_CASH_ACCOUNT_TYPE_TO_KIND = {
    "CACC": AccountKind.CURRENT,
    "SVGS": AccountKind.SAVINGS,
    "CARD": AccountKind.CARD,
    "OTHR": AccountKind.WALLET,
}


class EnableBankingProvider(BankProvider):
    """Enable Banking adapter, composing an :class:`EnableBankingClient`.

    Parameters
    ----------
    client : EnableBankingClient
        The authenticated HTTP client used for all provider calls.
    send_psu_headers : bool, optional
        Whether to actually attach :data:`_PSU_HEADERS` to a data-retrieval
        call when its ``SyncContext.psu_present`` is true. ``False`` by
        default and in production today (``Settings.send_psu_headers``,
        ADR 0011) — with it off, behavior is byte-for-byte what it was before
        this parameter existed, regardless of ``psu_present``.
    """

    def __init__(self, client: EnableBankingClient, *, send_psu_headers: bool = False) -> None:
        self._client = client
        self._send_psu_headers = send_psu_headers

    def _psu_headers_for(self, context: SyncContext) -> dict[str, str] | None:
        """Return the PSU headers for this call, or ``None`` to send none.

        ``None`` — not an empty dict — whenever either gate is off, so the
        client's ``extra_headers`` merge is skipped entirely rather than
        merging nothing (see :data:`_PSU_HEADERS`'s docstring for what's
        deliberately missing even when both gates are on).
        """
        if self._send_psu_headers and context.psu_present:
            return _PSU_HEADERS
        return None

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
        headers = self._psu_headers_for(context)
        session = self._client.get_session(credentials, extra_headers=headers)
        account_uids = session.get("accounts")
        if not isinstance(account_uids, list):
            raise ProviderError("Enable Banking /sessions response is missing 'accounts'")
        return [
            _to_provider_account(self._client.get_account_details(uid, extra_headers=headers))
            for uid in account_uids
        ]

    def fetch_transactions(
        self,
        *,
        credentials: str,
        account: Account,
        since: datetime,
        until: datetime | None,
        context: SyncContext,
    ) -> list[Transaction]:
        headers = self._psu_headers_for(context)
        if account.identification_hash is None:
            # Only a manual account (ADR 0020) has no identification_hash, and a
            # sync never iterates those — reaching here with one is a bug, not a
            # provider condition to handle gracefully.
            raise ProviderError(
                "cannot fetch transactions for an account with no provider identity"
            )
        account_uid = self._resolve_account_uid(
            credentials, account.identification_hash, extra_headers=headers
        )
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
                extra_headers=headers,
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

    def list_institutions(self, *, country: str) -> list[Institution]:
        aspsps = self._client.list_aspsps(country)
        institutions = []
        for aspsp in aspsps:
            name = aspsp.get("name")
            aspsp_country = aspsp.get("country")
            if not isinstance(name, str) or not isinstance(aspsp_country, str):
                raise ProviderError("Enable Banking /aspsps entry is missing 'name' or 'country'")
            institutions.append(Institution(name=name, country=aspsp_country))
        return institutions

    def _resolve_account_uid(
        self, credentials: str, identification_hash: str, *, extra_headers: dict[str, str] | None
    ) -> str:
        """Resolve the Enable Banking account UID for a stored account.

        The domain :class:`Account` carries the stable ``identification_hash`` but
        not the provider's session-scoped ``account_uid`` (the ``ProviderAccount``
        boundary deliberately drops it), so the uid is re-resolved here: list the
        session's uids and match on the ``identification_hash`` from each account's
        details. Stateless, at the cost of the extra detail calls — acceptable at
        the handful-of-accounts scale this runs at.
        """
        session = self._client.get_session(credentials, extra_headers=extra_headers)
        account_uids = session.get("accounts")
        if not isinstance(account_uids, list):
            raise ProviderError("Enable Banking /sessions response is missing 'accounts'")
        for uid in account_uids:
            details = self._client.get_account_details(uid, extra_headers=extra_headers)
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
