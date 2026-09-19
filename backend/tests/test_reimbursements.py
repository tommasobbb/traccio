"""Tests for the pure reimbursement/advance-state logic (``domain/advances``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts) — see ``docs/engineering.md``.
"""

from uuid import UUID, uuid4

import pytest

from traccio.domain import (
    KeyStrategy,
    Money,
    Participant,
    ParticipantStatus,
    Reimbursement,
    Transaction,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.advances import (
    REASON_CURRENCY_MISMATCH,
    REASON_NONPOSITIVE_AMOUNT,
    REASON_NOT_INCOMING,
    REASON_NOT_PERSONAL,
    REASON_REJECTED,
    ReimbursementError,
    derive_advance,
    derive_participant_states,
    group_reimbursements_by_participant,
    person_key,
    summarize_people,
    total_receivable,
    validate_reimbursement,
)
from traccio.domain.enums import AdvanceStatus


def _tx(
    *,
    amount: int = -5000,
    currency: str = "EUR",
    role: TransactionRole = TransactionRole.PERSONAL,
    status: TransactionStatus = TransactionStatus.BOOKED,
) -> Transaction:
    """Build a synthetic transaction."""
    return Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=amount, currency=currency),
        description="TEST MERCHANT 01",
        status=status,
        role=role,
        stable_key="TX-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def _eur(amount: int) -> Money:
    return Money(amount=amount, currency="EUR")


# --- derive_advance ---------------------------------------------------------


def test_open_when_nothing_reimbursed() -> None:
    """No reimbursements: outstanding equals the full receivable, status open."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=False)
    assert state.receivable == _eur(4000)
    assert state.reimbursed == _eur(0)
    assert state.outstanding == _eur(4000)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.OPEN
    # Spending share is just own_share, signed to match the outgoing spend.
    assert state.spending_share == _eur(-1000)


def test_partial_reimbursement_reduces_outstanding_and_stays_open() -> None:
    """A partial reimbursement lowers outstanding but does not settle."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(1500), written_off=False)
    assert state.outstanding == _eur(2500)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.OPEN
    assert state.spending_share == _eur(-1000)


def test_full_reimbursement_settles() -> None:
    """When reimbursements cover the receivable the advance is settled."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(4000), written_off=False)
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(0)
    assert state.status is AdvanceStatus.SETTLED
    # Own share is still the only real spending.
    assert state.spending_share == _eur(-1000)


def test_over_reimbursement_is_flagged_not_absorbed() -> None:
    """Reimbursing beyond the receivable clamps outstanding and flags the excess."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(4500), written_off=False)
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(500)
    assert state.status is AdvanceStatus.SETTLED


def test_write_off_moves_outstanding_into_spending() -> None:
    """A written-off advance spends own_share plus whatever was never paid back."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(1500), written_off=True)
    assert state.status is AdvanceStatus.WRITTEN_OFF
    assert state.outstanding == _eur(2500)
    # Spending = own_share (1000) + outstanding (2500), signed negative.
    assert state.spending_share == _eur(-3500)


def test_write_off_with_no_reimbursements_spends_the_whole_amount() -> None:
    """Writing off an untouched advance makes the full amount spending."""
    state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=True)
    assert state.spending_share == _eur(-5000)


def test_derive_requires_matching_currencies() -> None:
    """own_share and reimbursed must share the transaction's currency."""
    with pytest.raises(ValueError, match="currency"):
        derive_advance(
            _tx(currency="EUR"), _eur(1000), Money(amount=0, currency="USD"), written_off=False
        )


# --- validate_reimbursement -------------------------------------------------


def test_validate_accepts_a_clean_cash_reimbursement() -> None:
    """A positive cash amount in the advance currency validates."""
    validate_reimbursement(_eur(1000), "EUR", transaction=None)  # does not raise


def test_validate_accepts_a_clean_linked_transaction() -> None:
    """A personal, incoming, same-currency transaction may be linked."""
    validate_reimbursement(_eur(1000), "EUR", transaction=_tx(amount=2000))  # does not raise


def test_validate_rejects_nonpositive_amount() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(_eur(0), "EUR", transaction=None)
    assert exc.value.reason == REASON_NONPOSITIVE_AMOUNT


def test_validate_rejects_currency_mismatch() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(Money(amount=1000, currency="USD"), "EUR", transaction=None)
    assert exc.value.reason == REASON_CURRENCY_MISMATCH


def test_validate_rejects_outgoing_linked_transaction() -> None:
    """A linked transaction must be incoming (money received)."""
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(_eur(1000), "EUR", transaction=_tx(amount=-2000))
    assert exc.value.reason == REASON_NOT_INCOMING


def test_validate_rejects_non_personal_linked_transaction() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(
            _eur(1000), "EUR", transaction=_tx(amount=2000, role=TransactionRole.TRANSFER)
        )
    assert exc.value.reason == REASON_NOT_PERSONAL


def test_validate_rejects_rejected_linked_transaction() -> None:
    with pytest.raises(ReimbursementError) as exc:
        validate_reimbursement(
            _eur(1000), "EUR", transaction=_tx(amount=2000, status=TransactionStatus.REJECTED)
        )
    assert exc.value.reason == REASON_REJECTED


# --- group_reimbursements_by_participant / derive_participant_states (ADR 0012) -


def _participant(*, expected_amount: int = 4000) -> Participant:
    return Participant(name="TEST FRIEND 01", expected_amount=_eur(expected_amount))


def _reimbursement(*, participant_id: UUID | None, amount: int = 1000) -> Reimbursement:
    return Reimbursement(
        user_id=uuid4(),
        advance_id=uuid4(),
        amount=_eur(amount),
        participant_id=participant_id,
    )


def test_group_reimbursements_sums_per_participant_and_ignores_unattributed() -> None:
    alice = uuid4()
    bob = uuid4()
    totals = group_reimbursements_by_participant(
        [
            _reimbursement(participant_id=alice, amount=1000),
            _reimbursement(participant_id=alice, amount=500),
            _reimbursement(participant_id=bob, amount=2000),
            _reimbursement(participant_id=None, amount=9999),
        ]
    )
    assert totals == {alice: _eur(1500), bob: _eur(2000)}


def test_group_reimbursements_of_an_empty_list_is_empty() -> None:
    assert group_reimbursements_by_participant([]) == {}


def test_derive_participant_states_outstanding_when_nothing_reimbursed() -> None:
    participant = _participant(expected_amount=4000)
    [state] = derive_participant_states([participant], {}, currency="EUR")
    assert state.participant.id == participant.id
    assert state.reimbursed == _eur(0)
    assert state.outstanding == _eur(4000)
    assert state.excess == _eur(0)
    assert state.status is ParticipantStatus.OUTSTANDING


def test_derive_participant_states_settled_on_exact_match() -> None:
    participant = _participant(expected_amount=4000)
    [state] = derive_participant_states([participant], {participant.id: _eur(4000)}, currency="EUR")
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(0)
    assert state.status is ParticipantStatus.SETTLED


def test_derive_participant_states_settled_and_flags_excess_on_overpayment() -> None:
    participant = _participant(expected_amount=4000)
    [state] = derive_participant_states([participant], {participant.id: _eur(4500)}, currency="EUR")
    assert state.outstanding == _eur(0)
    assert state.excess == _eur(500)
    assert state.status is ParticipantStatus.SETTLED


def test_derive_participant_states_partial_reimbursement_stays_outstanding() -> None:
    participant = _participant(expected_amount=4000)
    [state] = derive_participant_states([participant], {participant.id: _eur(1500)}, currency="EUR")
    assert state.outstanding == _eur(2500)
    assert state.excess == _eur(0)
    assert state.status is ParticipantStatus.OUTSTANDING


def test_derive_participant_states_preserves_input_order_for_multiple_participants() -> None:
    alice = _participant(expected_amount=1000)
    bob = _participant(expected_amount=2000)
    states = derive_participant_states([alice, bob], {alice.id: _eur(1000)}, currency="EUR")
    assert [s.participant.id for s in states] == [alice.id, bob.id]
    assert states[0].status is ParticipantStatus.SETTLED
    assert states[1].status is ParticipantStatus.OUTSTANDING


# --- summarize_people / total_receivable (ADR 0026) -----------------------------


def _named(name: str, *, expected_amount: int) -> Participant:
    return Participant(name=name, expected_amount=_eur(expected_amount))


def _states(*participants_and_reimbursed: tuple[Participant, int], currency: str = "EUR") -> list:
    """One advance's participant states: a (participant, reimbursed) pair each."""
    participants = [p for p, _ in participants_and_reimbursed]
    reimbursed = {p.id: _eur(amount) for p, amount in participants_and_reimbursed}
    return derive_participant_states(participants, reimbursed, currency=currency)


def test_person_key_folds_case_and_whitespace() -> None:
    assert person_key("Marco") == person_key("  marco ") == person_key("MARCO")
    assert person_key("Marco  Rossi") == person_key("marco rossi")
    assert person_key("Marco") != person_key("Mardo")


def test_summarize_people_rolls_one_person_across_advances() -> None:
    marco_a = _named("Marco", expected_amount=3000)
    marco_b = _named(" marco ", expected_amount=2000)
    summaries = summarize_people([_states((marco_a, 1000)), _states((marco_b, 0))])
    assert len(summaries) == 1
    person = summaries[0]
    assert person.name == "Marco"  # first spelling seen, whitespace collapsed
    assert person.expected == _eur(5000)
    assert person.reimbursed == _eur(1000)
    assert person.outstanding == _eur(4000)
    assert person.advance_count == 2


def test_summarize_people_keeps_currencies_separate() -> None:
    marco_eur = _named("Marco", expected_amount=3000)
    marco_usd = _named("Marco", expected_amount=4000)
    summaries = summarize_people([_states((marco_eur, 0)), _states((marco_usd, 0), currency="USD")])
    assert {(s.name, s.currency) for s in summaries} == {("Marco", "EUR"), ("Marco", "USD")}
    assert all(s.advance_count == 1 for s in summaries)


def test_summarize_people_orders_by_outstanding_then_name() -> None:
    small = _named("Aldo", expected_amount=1000)
    big = _named("Zoe", expected_amount=9000)
    summaries = summarize_people([_states((small, 0), (big, 0))])
    assert [s.name for s in summaries] == ["Zoe", "Aldo"]


def test_summarize_people_of_nothing_is_empty() -> None:
    assert summarize_people([]) == []
    assert summarize_people([[]]) == []


def test_total_receivable_sums_outstanding_per_currency() -> None:
    a = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=False)
    b = derive_advance(_tx(amount=-3000), _eur(500), _eur(1000), written_off=False)
    [total] = total_receivable([a, b])
    assert total.currency == "EUR"
    assert total.outstanding == _eur(4000 + 1500)
    assert total.expected == _eur(4000 + 2500)  # receivable: (5000-1000) + (3000-500)
    assert total.reimbursed == _eur(0 + 1000)
    assert total.open_advances == 2


def test_total_receivable_excludes_written_off_and_counts_only_open() -> None:
    open_advance = derive_advance(_tx(amount=-5000), _eur(1000), _eur(0), written_off=False)
    settled = derive_advance(_tx(amount=-2000), _eur(500), _eur(1500), written_off=False)
    written_off = derive_advance(_tx(amount=-9000), _eur(1000), _eur(0), written_off=True)
    [total] = total_receivable([open_advance, settled, written_off])
    assert total.outstanding == _eur(4000)  # only the open advance contributes
    # expected/reimbursed follow the same written-off exclusion as outstanding
    # — the written-off advance's 8000 receivable never enters the sum.
    assert total.expected == _eur(4000 + 1500)
    assert total.reimbursed == _eur(0 + 1500)
    assert total.open_advances == 1


def test_total_receivable_expected_and_reimbursed_can_diverge_from_outstanding() -> None:
    """An over-reimbursed advance clamps `outstanding` at zero but not
    `expected`/`reimbursed` — mirroring PersonSummary's own excess handling."""
    over_reimbursed = derive_advance(_tx(amount=-5000), _eur(1000), _eur(6000), written_off=False)
    [total] = total_receivable([over_reimbursed])
    assert total.outstanding == _eur(0)  # clamped
    assert total.expected == _eur(4000)  # receivable: 5000-1000
    assert total.reimbursed == _eur(6000)  # not clamped


def test_total_and_per_person_diverge_on_an_unattributed_reimbursement() -> None:
    """A reimbursement with no participant_id lowers the advance's outstanding but
    no person's — the totals card must be free to show more than the people card."""
    friend = _named("Giulia", expected_amount=4000)
    # Advance receivable 4000; 1000 reimbursed but attributed to nobody.
    advance_state = derive_advance(_tx(amount=-5000), _eur(1000), _eur(1000), written_off=False)
    people = summarize_people([_states((friend, 0))])
    totals = total_receivable([advance_state])
    assert people[0].outstanding == _eur(4000)
    assert totals[0].outstanding == _eur(3000)
