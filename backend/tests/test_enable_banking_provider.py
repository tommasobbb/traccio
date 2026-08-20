"""Tests for the Enable Banking consent adapter.

Offline: an ``httpx.MockTransport`` serves canned ``/auth`` and ``/sessions``
responses so no network is touched. Credentials are a synthetic in-test RSA key;
the session id and codes are synthetic (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from traccio.domain import Account
from traccio.domain.enums import AccountKind, ConnectionStatus
from traccio.providers.base import AuthorizationStart, ProviderError, SyncContext
from traccio.providers.enable_banking.client import EnableBankingClient
from traccio.providers.enable_banking.provider import EnableBankingProvider

_APPLICATION_ID = "synthetic-app-id-01"
_SESSION_ID = "11111111-2222-3333-4444-555555555555"
_REDIRECT_URL = "https://localhost:8000/connections/callback"


def _synthetic_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")


def _provider(handler: httpx.MockTransport) -> EnableBankingProvider:
    client = EnableBankingClient(
        application_id=_APPLICATION_ID,
        private_key_pem=_synthetic_pem(),
        transport=handler,
    )
    return EnableBankingProvider(client)


def test_start_authorization_builds_auth_request_and_returns_start() -> None:
    """start_authorization POSTs a well-formed /auth body and returns the SCA url."""
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        captured["path"] = request.url.path
        captured["body"] = _json.loads(request.content)
        return httpx.Response(
            200, json={"url": "https://sca.example/authorize?x=1", "authorization_id": "auth-01"}
        )

    provider = _provider(httpx.MockTransport(handler))

    start = provider.start_authorization(
        institution="Test Bank 01", country="IT", redirect_url=_REDIRECT_URL
    )

    assert isinstance(start, AuthorizationStart)
    assert captured["path"] == "/auth"
    body = captured["body"]
    assert body["aspsp"] == {"name": "Test Bank 01", "country": "IT"}
    assert body["redirect_url"] == _REDIRECT_URL
    assert body["psu_type"] == "personal"
    assert body["state"]  # non-empty anti-CSRF token
    # valid_until is requested ~180 days out, timezone-aware.
    valid_until = datetime.fromisoformat(body["access"]["valid_until"])
    assert valid_until.tzinfo is not None
    assert 170 < (valid_until - datetime.now(UTC)).days <= 180
    # The returned session_reference is exactly the state that was sent.
    assert start.authorization_url == "https://sca.example/authorize?x=1"
    assert start.session_reference == body["state"]


def test_complete_authorization_exchanges_code_for_session() -> None:
    """A matching-state callback exchanges the code and maps to an AuthorizationResult."""
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        captured["path"] = request.url.path
        captured["body"] = _json.loads(request.content)
        return httpx.Response(
            200,
            json={
                "session_id": _SESSION_ID,
                "accounts": [],
                "access": {"valid_until": "2027-02-16T00:00:00+00:00"},
            },
        )

    provider = _provider(httpx.MockTransport(handler))

    result = provider.complete_authorization(
        session_reference="STATE-01",
        callback_payload={"state": "STATE-01", "code": "AUTH-CODE-01"},
    )

    assert captured["path"] == "/sessions"
    assert captured["body"] == {"code": "AUTH-CODE-01"}
    assert result.credentials == _SESSION_ID
    assert result.status is ConnectionStatus.ACTIVE
    assert result.expires_at == datetime(2027, 2, 16, tzinfo=UTC)


def test_complete_authorization_rejects_state_mismatch() -> None:
    """A callback whose state does not match the reference is refused (CSRF guard)."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("/sessions must not be called on a state mismatch")

    provider = _provider(httpx.MockTransport(handler))

    with pytest.raises(ProviderError):
        provider.complete_authorization(
            session_reference="STATE-01",
            callback_payload={"state": "WRONG", "code": "AUTH-CODE-01"},
        )


def test_complete_authorization_surfaces_callback_error() -> None:
    """An error in the callback payload raises without echoing its detail."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("/sessions must not be called when the callback errored")

    provider = _provider(httpx.MockTransport(handler))

    with pytest.raises(ProviderError) as excinfo:
        provider.complete_authorization(
            session_reference="STATE-01",
            callback_payload={
                "state": "STATE-01",
                "error": "access_denied",
                "error_description": "user-secret-detail",
            },
        )

    assert "user-secret-detail" not in str(excinfo.value)


def test_authorization_result_hides_the_session_credential() -> None:
    """The session_id credential is excluded from repr so a whole-object log can't leak it."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "session_id": _SESSION_ID,
                "accounts": [],
                "access": {"valid_until": "2027-02-16T00:00:00+00:00"},
            },
        )

    provider = _provider(httpx.MockTransport(handler))

    result = provider.complete_authorization(
        session_reference="STATE-01",
        callback_payload={"state": "STATE-01", "code": "AUTH-CODE-01"},
    )

    assert _SESSION_ID not in repr(result)


# Synthetic account details (invented IBAN, holder name, product) — see
# .claude/rules/data-safety.md. The holder name and IBAN must never surface in
# the normalized ProviderAccount.
_IBAN = "IT60X0542811101000000123456"
_HOLDER_NAME = "MARIO ROSSI"
_DETAILS = {
    "uid-curr-01": {
        "uid": "uid-curr-01",
        "identification_hash": "IDHASH-CURR-01",
        "account_id": {"iban": _IBAN},
        "cash_account_type": "CACC",
        "currency": "EUR",
        "product": "TEST CURRENT 01",
        "name": _HOLDER_NAME,
    },
    "uid-card-01": {
        "uid": "uid-card-01",
        "identification_hash": "IDHASH-CARD-01",
        "account_id": {"other": {"identification": "MASKED-01"}},
        "cash_account_type": "CARD",
        "currency": "EUR",
        "product": "TEST CARD 01",
    },
}


def _accounts_handler(
    *, session_body: dict[str, Any], details: dict[str, dict[str, Any]]
) -> httpx.MockTransport:
    """Serve GET /sessions/{id} then GET /accounts/{uid}/details from canned data."""

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == f"/sessions/{_SESSION_ID}":
            return httpx.Response(200, json=session_body)
        prefix, _, suffix = path.partition("/accounts/")
        if prefix == "" and suffix.endswith("/details"):
            uid = suffix.removesuffix("/details")
            return httpx.Response(200, json=details[uid])
        raise AssertionError(f"unexpected path: {path}")

    return httpx.MockTransport(handler)


def test_list_accounts_maps_session_accounts_to_provider_accounts() -> None:
    """list_accounts fans out over the session's uids and normalizes each account."""
    provider = _provider(
        _accounts_handler(
            session_body={"accounts": ["uid-curr-01", "uid-card-01"]}, details=_DETAILS
        )
    )

    accounts = provider.list_accounts(
        credentials=_SESSION_ID, context=SyncContext(psu_present=True)
    )

    assert len(accounts) == 2
    by_hash = {a.identification_hash: a for a in accounts}
    assert by_hash["IDHASH-CURR-01"].kind is AccountKind.CURRENT
    assert by_hash["IDHASH-CURR-01"].currency == "EUR"
    # The display name is the bank product, not the account holder.
    assert by_hash["IDHASH-CURR-01"].name == "TEST CURRENT 01"
    assert by_hash["IDHASH-CARD-01"].kind is AccountKind.CARD


def test_list_accounts_never_exposes_iban_or_holder_name() -> None:
    """The raw IBAN and the account-holder name stay inside the adapter (data-safety)."""
    provider = _provider(
        _accounts_handler(
            session_body={"accounts": ["uid-curr-01"]},
            details={"uid-curr-01": _DETAILS["uid-curr-01"]},
        )
    )

    accounts = provider.list_accounts(
        credentials=_SESSION_ID, context=SyncContext(psu_present=True)
    )

    blob = repr(accounts)
    assert _IBAN not in blob
    assert _HOLDER_NAME not in blob


def test_list_accounts_rejects_unsupported_account_type() -> None:
    """A cash_account_type outside the modelled kinds fails loudly rather than coercing."""
    details = {"uid-loan-01": {**_DETAILS["uid-curr-01"], "cash_account_type": "LOAN"}}
    provider = _provider(
        _accounts_handler(session_body={"accounts": ["uid-loan-01"]}, details=details)
    )

    with pytest.raises(ProviderError):
        provider.list_accounts(credentials=_SESSION_ID, context=SyncContext(psu_present=True))


def test_list_accounts_rejects_malformed_details() -> None:
    """Missing a required field surfaces as a value-free ProviderError."""
    details = {"uid-x": {"cash_account_type": "CACC", "currency": "EUR"}}  # no identification_hash
    provider = _provider(_accounts_handler(session_body={"accounts": ["uid-x"]}, details=details))

    with pytest.raises(ProviderError):
        provider.list_accounts(credentials=_SESSION_ID, context=SyncContext(psu_present=True))


def test_list_accounts_rejects_session_without_accounts() -> None:
    """A session response lacking the accounts list is a malformed payload."""
    provider = _provider(_accounts_handler(session_body={}, details={}))

    with pytest.raises(ProviderError):
        provider.list_accounts(credentials=_SESSION_ID, context=SyncContext(psu_present=True))


def _transactions_handler(
    *,
    accounts: list[str],
    details: dict[str, dict[str, Any]],
    pages: dict[str, dict[str, Any]],
) -> httpx.MockTransport:
    """Serve session/details (for uid resolution) then transactions pages.

    ``pages`` is keyed by the incoming ``continuation_key`` (``""`` for the first
    request), so a page carrying ``continuation_key`` chains to the next.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == f"/sessions/{_SESSION_ID}":
            return httpx.Response(200, json={"accounts": accounts})
        prefix, _, suffix = path.partition("/accounts/")
        if prefix == "" and suffix.endswith("/details"):
            return httpx.Response(200, json=details[suffix.removesuffix("/details")])
        if prefix == "" and suffix.endswith("/transactions"):
            key = request.url.params.get("continuation_key", "")
            return httpx.Response(200, json=pages[key])
        raise AssertionError(f"unexpected path: {path}")

    return httpx.MockTransport(handler)


def _account(identification_hash: str = "IDHASH-CURR-01") -> Account:
    return Account(
        user_id=uuid4(),
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
    )


def _raw_tx(entry_reference: str, amount: str = "12.34") -> dict[str, Any]:
    return {
        "entry_reference": entry_reference,
        "transaction_amount": {"currency": "EUR", "amount": amount},
        "credit_debit_indicator": "DBIT",
        "status": "BOOK",
        "booking_date": "2026-08-15",
        "value_date": "2026-08-16",
        "remittance_information": ["TEST MERCHANT 01"],
    }


def test_fetch_transactions_resolves_uid_and_normalizes() -> None:
    """The adapter matches identification_hash to a uid, then normalizes each entry."""
    account = _account("IDHASH-CURR-01")
    provider = _provider(
        _transactions_handler(
            accounts=["uid-curr-01"],
            details=_DETAILS,
            pages={"": {"transactions": [_raw_tx("ENTRY-01")]}},
        )
    )

    txs = provider.fetch_transactions(
        credentials=_SESSION_ID,
        account=account,
        since=datetime(2026, 1, 1, tzinfo=UTC),
        until=None,
        context=SyncContext(psu_present=True),
    )

    assert len(txs) == 1
    assert txs[0].account_id == account.id
    assert txs[0].money.amount == -1234
    assert txs[0].stable_key == "ENTRY-01"


def test_fetch_transactions_follows_pagination() -> None:
    """A page carrying a continuation_key is chained until one omits it."""
    provider = _provider(
        _transactions_handler(
            accounts=["uid-curr-01"],
            details=_DETAILS,
            pages={
                "": {"transactions": [_raw_tx("ENTRY-01")], "continuation_key": "PAGE2"},
                "PAGE2": {"transactions": [_raw_tx("ENTRY-02")]},
            },
        )
    )

    txs = provider.fetch_transactions(
        credentials=_SESSION_ID,
        account=_account("IDHASH-CURR-01"),
        since=datetime(2026, 1, 1, tzinfo=UTC),
        until=None,
        context=SyncContext(psu_present=True),
    )

    assert [t.stable_key for t in txs] == ["ENTRY-01", "ENTRY-02"]


def test_fetch_transactions_rejects_account_not_in_session() -> None:
    """An account whose identification_hash no uid matches fails loudly."""
    provider = _provider(
        _transactions_handler(
            accounts=["uid-curr-01"],
            details=_DETAILS,
            pages={"": {"transactions": []}},
        )
    )

    with pytest.raises(ProviderError):
        provider.fetch_transactions(
            credentials=_SESSION_ID,
            account=_account("IDHASH-NOT-PRESENT"),
            since=datetime(2026, 1, 1, tzinfo=UTC),
            until=None,
            context=SyncContext(psu_present=True),
        )


def test_provider_name_is_stable() -> None:
    """The provider identifier is stable and safe to log."""
    provider = _provider(httpx.MockTransport(lambda request: httpx.Response(200, json={})))

    assert provider.name == "enable_banking"
