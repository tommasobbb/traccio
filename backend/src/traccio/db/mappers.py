"""Pure translation between domain entities and ORM rows.

The domain layer knows nothing about persistence, so the mapping lives here.
These functions are pure — no session, no I/O — which keeps them testable
without a database. The only non-trivial mapping is :class:`Money`, which the
domain carries as one value object and the schema stores as two columns
(``amount`` + ``currency``).
"""

from collections.abc import Sequence
from uuid import UUID

from traccio.db.models import (
    AccountRow,
    AdvanceParticipantRow,
    AdvanceRow,
    CategoryRow,
    ConnectionRow,
    EventRow,
    ReimbursementRow,
    RuleRow,
    SyncRunRow,
    TransactionRow,
    TransferRow,
    UserRow,
)
from traccio.domain.models import (
    Account,
    Advance,
    Category,
    Connection,
    Event,
    Participant,
    Reimbursement,
    Rule,
    SyncRun,
    Transaction,
    Transfer,
    User,
)
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
        country=connection.country,
        status=connection.status,
        expires_at=connection.expires_at,
        created_at=connection.created_at,
        last_synced_at=connection.last_synced_at,
    )


def row_to_connection(row: ConnectionRow) -> Connection:
    """Translate a :class:`ConnectionRow` into a domain :class:`Connection`."""
    return Connection(
        id=row.id,
        user_id=row.user_id,
        provider=row.provider,
        institution_name=row.institution_name,
        country=row.country,
        status=row.status,
        expires_at=row.expires_at,
        created_at=row.created_at,
        last_synced_at=row.last_synced_at,
    )


def account_to_row(account: Account) -> AccountRow:
    """Translate a domain :class:`Account` into an :class:`AccountRow`.

    Used to build the row for a *fresh* sync-time insert. Deliberately
    includes ``alias``/``color``/``icon`` here (unlike, say, a category id on
    a transaction) because on a first insert there is nothing to preserve yet;
    the field that must never be overwritten on an *existing* row is guarded
    in :func:`traccio.db.repositories.upsert_account` instead, not here.
    """
    return AccountRow(
        id=account.id,
        user_id=account.user_id,
        connection_id=account.connection_id,
        kind=account.kind,
        currency=account.currency,
        identification_hash=account.identification_hash,
        name=account.name,
        alias=account.alias,
        color=account.color,
        icon=account.icon,
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
        alias=row.alias,
        color=row.color,
        icon=row.icon,
        created_at=row.created_at,
    )


def transaction_to_row(transaction: Transaction) -> TransactionRow:
    """Translate a domain :class:`Transaction` into a :class:`TransactionRow`.

    Splits ``money`` into the ``amount`` and ``currency`` columns.

    Deliberately does **not** write ``suggested_category_id`` or
    ``confirmed_category_id`` — same as it never wrote ``event_id``. This
    mapper is used to build the row for a fresh sync, so a written category id
    here would mean a sync could set or clear a category, which is exactly the
    automated write ``docs/domain.md`` §Category forbids for ``confirmed``.
    The only writers are :func:`traccio.db.repositories.set_confirmed_category`
    (explicit user action) and :func:`traccio.db.repositories.set_suggested_categories`
    (the rules engine) — neither goes through this function.
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

    Recomposes ``money`` from the ``amount`` and ``currency`` columns. Reads
    (but, unlike this function's counterpart, never writes) both category ids.
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
        suggested_category_id=row.suggested_category_id,
        confirmed_category_id=row.confirmed_category_id,
    )


def advance_to_row(advance: Advance) -> AdvanceRow:
    """Translate a domain :class:`Advance` into an :class:`AdvanceRow`.

    Splits ``own_share`` into the ``own_share_amount``/``own_share_currency``
    columns. Participants are mapped separately (see :func:`participant_to_row`),
    since they are their own rows.
    """
    return AdvanceRow(
        id=advance.id,
        user_id=advance.user_id,
        transaction_id=advance.transaction_id,
        own_share_amount=advance.own_share.amount,
        own_share_currency=advance.own_share.currency,
        status=advance.status,
        created_at=advance.created_at,
    )


def participant_to_row(
    participant: Participant, *, user_id: UUID, advance_id: UUID
) -> AdvanceParticipantRow:
    """Translate a domain :class:`Participant` into an :class:`AdvanceParticipantRow`.

    The ``user_id`` and ``advance_id`` are supplied by the caller (they live on
    the parent :class:`Advance`, not on the value object). Uses
    ``participant.id`` rather than minting a fresh one — the domain model now
    carries a stable id (ADR 0012, previously discarded on every read), so
    round-tripping through this mapper must preserve it, not replace it.
    """
    return AdvanceParticipantRow(
        id=participant.id,
        user_id=user_id,
        advance_id=advance_id,
        name=participant.name,
        expected_amount=participant.expected_amount.amount,
        expected_currency=participant.expected_amount.currency,
    )


def row_to_participant(row: AdvanceParticipantRow) -> Participant:
    """Translate an :class:`AdvanceParticipantRow` into a domain :class:`Participant`."""
    return Participant(
        id=row.id,
        name=row.name,
        expected_amount=Money(amount=row.expected_amount, currency=row.expected_currency),
    )


def row_to_advance(row: AdvanceRow, participant_rows: Sequence[AdvanceParticipantRow]) -> Advance:
    """Translate an :class:`AdvanceRow` (+ its participants) into a domain :class:`Advance`.

    Recomposes ``own_share`` from its two columns and attaches the participants.
    """
    return Advance(
        id=row.id,
        user_id=row.user_id,
        transaction_id=row.transaction_id,
        own_share=Money(amount=row.own_share_amount, currency=row.own_share_currency),
        status=row.status,
        participants=[row_to_participant(p) for p in participant_rows],
        created_at=row.created_at,
    )


def transfer_to_row(transfer: Transfer) -> TransferRow:
    """Translate a domain :class:`Transfer` into a :class:`TransferRow`."""
    return TransferRow(
        id=transfer.id,
        user_id=transfer.user_id,
        outgoing_transaction_id=transfer.outgoing_transaction_id,
        incoming_transaction_id=transfer.incoming_transaction_id,
        created_at=transfer.created_at,
    )


def row_to_transfer(row: TransferRow) -> Transfer:
    """Translate a :class:`TransferRow` into a domain :class:`Transfer`."""
    return Transfer(
        id=row.id,
        user_id=row.user_id,
        outgoing_transaction_id=row.outgoing_transaction_id,
        incoming_transaction_id=row.incoming_transaction_id,
        created_at=row.created_at,
    )


def reimbursement_to_row(reimbursement: Reimbursement) -> ReimbursementRow:
    """Translate a domain :class:`Reimbursement` into a :class:`ReimbursementRow`.

    Splits ``amount`` into the ``amount``/``currency`` columns like every other
    :class:`Money` mapping.
    """
    return ReimbursementRow(
        id=reimbursement.id,
        user_id=reimbursement.user_id,
        advance_id=reimbursement.advance_id,
        amount=reimbursement.amount.amount,
        currency=reimbursement.amount.currency,
        transaction_id=reimbursement.transaction_id,
        participant_id=reimbursement.participant_id,
        note=reimbursement.note,
        created_at=reimbursement.created_at,
    )


def row_to_reimbursement(row: ReimbursementRow) -> Reimbursement:
    """Translate a :class:`ReimbursementRow` into a domain :class:`Reimbursement`.

    Recomposes ``amount`` from its two columns.
    """
    return Reimbursement(
        id=row.id,
        user_id=row.user_id,
        advance_id=row.advance_id,
        amount=Money(amount=row.amount, currency=row.currency),
        transaction_id=row.transaction_id,
        participant_id=row.participant_id,
        note=row.note,
        created_at=row.created_at,
    )


def event_to_row(event: Event) -> EventRow:
    """Translate a domain :class:`Event` into an :class:`EventRow`.

    Membership (``transactions.event_id``) is not part of the event and is
    handled by the repository, not here.
    """
    return EventRow(
        id=event.id,
        user_id=event.user_id,
        name=event.name,
        start_date=event.start_date,
        end_date=event.end_date,
        status=event.status,
        created_at=event.created_at,
    )


def row_to_event(row: EventRow) -> Event:
    """Translate an :class:`EventRow` into a domain :class:`Event`."""
    return Event(
        id=row.id,
        user_id=row.user_id,
        name=row.name,
        start_date=row.start_date,
        end_date=row.end_date,
        status=row.status,
        created_at=row.created_at,
    )


def category_to_row(category: Category) -> CategoryRow:
    """Translate a domain :class:`Category` into a :class:`CategoryRow`."""
    return CategoryRow(
        id=category.id,
        user_id=category.user_id,
        name=category.name,
        parent_id=category.parent_id,
        color=category.color,
        icon=category.icon,
        created_at=category.created_at,
    )


def row_to_category(row: CategoryRow) -> Category:
    """Translate a :class:`CategoryRow` into a domain :class:`Category`."""
    return Category(
        id=row.id,
        user_id=row.user_id,
        name=row.name,
        parent_id=row.parent_id,
        color=row.color,
        icon=row.icon,
        created_at=row.created_at,
    )


def rule_to_row(rule: Rule) -> RuleRow:
    """Translate a domain :class:`Rule` into a :class:`RuleRow`."""
    return RuleRow(
        id=rule.id,
        user_id=rule.user_id,
        category_id=rule.category_id,
        match_kind=rule.match_kind,
        pattern=rule.pattern,
        created_at=rule.created_at,
    )


def row_to_rule(row: RuleRow) -> Rule:
    """Translate a :class:`RuleRow` into a domain :class:`Rule`."""
    return Rule(
        id=row.id,
        user_id=row.user_id,
        category_id=row.category_id,
        match_kind=row.match_kind,
        pattern=row.pattern,
        created_at=row.created_at,
    )


def sync_run_to_row(sync_run: SyncRun) -> SyncRunRow:
    """Translate a domain :class:`SyncRun` into a :class:`SyncRunRow`."""
    return SyncRunRow(
        id=sync_run.id,
        user_id=sync_run.user_id,
        connection_id=sync_run.connection_id,
        trigger=sync_run.trigger,
        outcome=sync_run.outcome,
        started_at=sync_run.started_at,
        finished_at=sync_run.finished_at,
        accounts_synced=sync_run.accounts_synced,
        transactions_synced=sync_run.transactions_synced,
        error_reason=sync_run.error_reason,
    )


def row_to_sync_run(row: SyncRunRow) -> SyncRun:
    """Translate a :class:`SyncRunRow` into a domain :class:`SyncRun`."""
    return SyncRun(
        id=row.id,
        user_id=row.user_id,
        connection_id=row.connection_id,
        trigger=row.trigger,
        outcome=row.outcome,
        started_at=row.started_at,
        finished_at=row.finished_at,
        accounts_synced=row.accounts_synced,
        transactions_synced=row.transactions_synced,
        error_reason=row.error_reason,
    )
