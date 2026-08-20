"""Tests for the bank provider adapter interface.

Pure unit tests: no database, no network, no provider SDK. A minimal in-memory
:class:`FakeBankProvider` stands in for a real adapter to prove the interface is
implementable and substitutable, and that its DTOs behave. Fixtures use
synthetic values only (invented references, round amounts) — see
``.claude/rules/data-safety.md``.
"""

from collections.abc import Mapping
from datetime import UTC, datetime
from uuid import UUID, uuid4

from traccio.domain import (
    Account,
    AccountKind,
    KeyStrategy,
    Money,
    Transaction,
    TransactionStatus,
)
from traccio.domain.enums import ConnectionStatus
from traccio.providers.base import (
    AuthorizationResult,
    AuthorizationStart,
    BankProvider,
    SyncContext,
)

_SECRET = "SESSION-SECRET-01"


class FakeBankProvider(BankProvider):
    """In-memory adapter returning synthetic domain objects.

    Records the ``SyncContext`` it was last called with so a test can assert the
    presence flag is threaded through.
    """

    def __init__(self, *, user_id: UUID) -> None:
        self._user_id = user_id
        self.last_context: SyncContext | None = None

    @property
    def name(self) -> str:
        return "fake"

    def start_authorization(self, *, institution: str, redirect_url: str) -> AuthorizationStart:
        return AuthorizationStart(
            authorization_url=f"https://auth.example/{institution}?redirect={redirect_url}",
            session_reference="SESSION-REF-01",
        )

    def complete_authorization(
        self, *, session_reference: str, callback_payload: Mapping[str, str]
    ) -> AuthorizationResult:
        assert session_reference == "SESSION-REF-01"
        return AuthorizationResult(
            credentials=_SECRET,
            status=ConnectionStatus.ACTIVE,
            expires_at=datetime(2026, 12, 31, tzinfo=UTC),
        )

    def list_accounts(self, *, credentials: str, context: SyncContext) -> list[Account]:
        self.last_context = context
        assert credentials == _SECRET
        return [
            Account(
                user_id=self._user_id,
                connection_id=uuid4(),
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash="hash-01",
            )
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
        self.last_context = context
        assert credentials == _SECRET
        return [
            Transaction(
                user_id=account.user_id,
                account_id=account.id,
                money=Money(amount=-1234, currency="EUR"),
                description="TEST MERCHANT 01",
                status=TransactionStatus.BOOKED,
                stable_key="entry-01",
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
            )
        ]


def test_fake_provider_is_a_bank_provider() -> None:
    """A concrete adapter is substitutable for the interface."""
    provider: BankProvider = FakeBankProvider(user_id=uuid4())

    assert provider.name == "fake"


def test_authorization_handshake_round_trips() -> None:
    """start_authorization → complete_authorization yields a usable consent."""
    provider = FakeBankProvider(user_id=uuid4())

    start = provider.start_authorization(institution="test-bank", redirect_url="traccio://callback")
    result = provider.complete_authorization(
        session_reference=start.session_reference,
        callback_payload={"code": "AUTH-CODE-01"},
    )

    assert result.status is ConnectionStatus.ACTIVE
    assert result.expires_at == datetime(2026, 12, 31, tzinfo=UTC)
    assert result.credentials == _SECRET


def test_list_accounts_returns_domain_accounts() -> None:
    """list_accounts returns domain Account objects, not provider payloads."""
    user_id = uuid4()
    provider = FakeBankProvider(user_id=user_id)

    accounts = provider.list_accounts(credentials=_SECRET, context=SyncContext(psu_present=True))

    assert len(accounts) == 1
    assert isinstance(accounts[0], Account)
    assert accounts[0].user_id == user_id


def test_fetch_transactions_returns_domain_transactions() -> None:
    """fetch_transactions returns normalized domain Transaction objects."""
    provider = FakeBankProvider(user_id=uuid4())
    account = provider.list_accounts(credentials=_SECRET, context=SyncContext(psu_present=True))[0]

    transactions = provider.fetch_transactions(
        credentials=_SECRET,
        account=account,
        since=datetime(2026, 1, 1, tzinfo=UTC),
        until=None,
        context=SyncContext(psu_present=False),
    )

    assert len(transactions) == 1
    assert isinstance(transactions[0], Transaction)
    assert transactions[0].account_id == account.id


def test_sync_context_is_threaded_to_the_adapter() -> None:
    """The presence flag reaches the adapter, which sets PSU headers from it."""
    provider = FakeBankProvider(user_id=uuid4())

    provider.list_accounts(credentials=_SECRET, context=SyncContext(psu_present=False))

    assert provider.last_context is not None
    assert provider.last_context.psu_present is False


def test_secret_fields_are_absent_from_repr() -> None:
    """Consent secrets are excluded from repr so a whole-object log can't leak them."""
    start = AuthorizationStart(
        authorization_url="https://auth.example/x", session_reference="SESSION-REF-01"
    )
    result = AuthorizationResult(credentials=_SECRET, status=ConnectionStatus.ACTIVE)

    assert "SESSION-REF-01" not in repr(start)
    assert _SECRET not in repr(result)
