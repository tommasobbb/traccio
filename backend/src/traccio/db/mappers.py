"""Pure translation between domain entities and ORM rows.

The domain layer knows nothing about persistence, so the mapping lives here.
These functions are pure — no session, no I/O — which keeps them testable
without a database. The only non-trivial mapping is :class:`Money`, which the
domain carries as one value object and the schema stores as two columns
(``amount`` + ``currency``).
"""

from traccio.db.models import (
    AccountRow,
    ConnectionRow,
    TransactionRow,
    UserRow,
)
from traccio.domain.models import Account, Connection, Transaction, User
from traccio.domain.money import Money


def user_to_row(user: User) -> UserRow:
    """Translate a domain :class:`User` into a :class:`UserRow`."""
    return UserRow(id=user.id, created_at=user.created_at)


def row_to_user(row: UserRow) -> User:
    """Translate a :class:`UserRow` into a domain :class:`User`."""
    return User(id=row.id, created_at=row.created_at)


def connection_to_row(connection: Connection) -> ConnectionRow:
    """Translate a domain :class:`Connection` into a :class:`ConnectionRow`."""
    return ConnectionRow(
        id=connection.id,
        user_id=connection.user_id,
        provider=connection.provider,
        institution_name=connection.institution_name,
        status=connection.status,
        expires_at=connection.expires_at,
        created_at=connection.created_at,
    )


def row_to_connection(row: ConnectionRow) -> Connection:
    """Translate a :class:`ConnectionRow` into a domain :class:`Connection`."""
    return Connection(
        id=row.id,
        user_id=row.user_id,
        provider=row.provider,
        institution_name=row.institution_name,
        status=row.status,
        expires_at=row.expires_at,
        created_at=row.created_at,
    )


def account_to_row(account: Account) -> AccountRow:
    """Translate a domain :class:`Account` into an :class:`AccountRow`."""
    return AccountRow(
        id=account.id,
        user_id=account.user_id,
        connection_id=account.connection_id,
        kind=account.kind,
        currency=account.currency,
        identification_hash=account.identification_hash,
        name=account.name,
        created_at=account.created_at,
    )


def row_to_account(row: AccountRow) -> Account:
    """Translate an :class:`AccountRow` into a domain :class:`Account`."""
    return Account(
        id=row.id,
        user_id=row.user_id,
        connection_id=row.connection_id,
        kind=row.kind,
        currency=row.currency,
        identification_hash=row.identification_hash,
        name=row.name,
        created_at=row.created_at,
    )


def transaction_to_row(transaction: Transaction) -> TransactionRow:
    """Translate a domain :class:`Transaction` into a :class:`TransactionRow`.

    Splits ``money`` into the ``amount`` and ``currency`` columns.
    """
    return TransactionRow(
        id=transaction.id,
        user_id=transaction.user_id,
        account_id=transaction.account_id,
        amount=transaction.money.amount,
        currency=transaction.money.currency,
        booked_at=transaction.booked_at,
        value_date=transaction.value_date,
        description=transaction.description,
        display_description=transaction.display_description,
        status=transaction.status,
        role=transaction.role,
        entry_reference=transaction.entry_reference,
        stable_key=transaction.stable_key,
        key_strategy=transaction.key_strategy,
    )


def row_to_transaction(row: TransactionRow) -> Transaction:
    """Translate a :class:`TransactionRow` into a domain :class:`Transaction`.

    Recomposes ``money`` from the ``amount`` and ``currency`` columns.
    """
    return Transaction(
        id=row.id,
        user_id=row.user_id,
        account_id=row.account_id,
        money=Money(amount=row.amount, currency=row.currency),
        booked_at=row.booked_at,
        value_date=row.value_date,
        description=row.description,
        display_description=row.display_description,
        status=row.status,
        role=row.role,
        entry_reference=row.entry_reference,
        stable_key=row.stable_key,
        key_strategy=row.key_strategy,
    )
