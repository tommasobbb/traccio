import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `EventDetailViewModel` against `FakeAPIClient` — no network
/// stub needed, per `.claude/rules/swift.md`'s "test the seam." Fixtures are
/// synthetic (`.claude/rules/data-safety.md`): invented ids, round amounts,
/// `"TEST MERCHANT 01"`.
@MainActor
struct EventDetailViewModelTests {
    private static let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let memberID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let candidateID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private static func makeEvent(
        memberCount: Int = 0, total: Int = 0, currency: String? = nil, status: EventStatus = .active
    ) -> EventResponse {
        EventResponse(
            id: eventID, name: "TEST TRIP 01", startDate: nil, endDate: nil, status: status,
            memberCount: memberCount, total: total, currency: currency,
            createdAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
    }

    private static func makeTransaction(
        id: UUID, amount: Int, currency: String = "EUR", eventID: UUID? = nil
    ) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: UUID(),
            amount: amount,
            effectiveAmount: amount,
            currency: currency,
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: .personal,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: eventID
        )
    }

    @Test func loadMembersPublishesTheFetchedList() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactions([Self.makeTransaction(id: Self.memberID, amount: -5000)])
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.loadMembers()

        #expect(model.members.count == 1)
        #expect(model.members[0].id == Self.memberID)
    }

    @Test func loadMembersFailureLeavesMembersEmpty() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactionsError(FakeAPIError())
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.loadMembers()

        #expect(model.members.isEmpty)
    }

    @Test func availableCandidatesExcludesCurrentMembers() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactions([Self.makeTransaction(id: Self.memberID, amount: -5000)])
        await client.setTransactions([
            Self.makeTransaction(id: Self.memberID, amount: -5000),
            Self.makeTransaction(id: Self.candidateID, amount: -2000),
        ])
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)
        await model.loadMembers()

        await model.loadCandidatesIfNeeded()

        #expect(model.availableCandidates.map(\.id) == [Self.candidateID])
    }

    @Test func availableCandidatesExcludesTransactionsAlreadyInAnotherEvent() async throws {
        let otherEventID = UUID()
        let client = FakeAPIClient()
        await client.setTransactions([
            Self.makeTransaction(id: Self.candidateID, amount: -2000),
            Self.makeTransaction(id: UUID(), amount: -3000, eventID: otherEventID),
        ])
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.loadCandidatesIfNeeded()

        #expect(model.availableCandidates.map(\.id) == [Self.candidateID])
    }

    @Test func availableCandidatesIncludesATransactionAlreadyInThisEvent() async throws {
        // A candidate whose eventID already matches this event (e.g. loaded
        // right after assignment) must not be excluded by the
        // another-event check — only `memberIDs` decides that.
        let client = FakeAPIClient()
        await client.setTransactions([
            Self.makeTransaction(id: Self.candidateID, amount: -2000, eventID: Self.eventID)
        ])
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.loadCandidatesIfNeeded()

        #expect(model.availableCandidates.map(\.id) == [Self.candidateID])
    }

    @Test func availableCandidatesNarrowsToTheEventCurrencyOnceKnown() async throws {
        let client = FakeAPIClient()
        await client.setTransactions([
            Self.makeTransaction(id: Self.candidateID, amount: -2000, currency: "EUR"),
            Self.makeTransaction(id: UUID(), amount: -2000, currency: "USD"),
        ])
        let model = EventDetailViewModel(event: Self.makeEvent(currency: "EUR"), client: client)

        await model.loadCandidatesIfNeeded()

        #expect(model.availableCandidates.map(\.id) == [Self.candidateID])
    }

    @Test func assignSuccessRefetchesEventAndMembers() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactions([Self.makeTransaction(id: Self.candidateID, amount: -2000)])
        await client.setEvent(Self.makeEvent(memberCount: 1, total: -2000, currency: "EUR"))
        var changedEvents: [EventResponse] = []
        let model = EventDetailViewModel(
            event: Self.makeEvent(), client: client, onEventChange: { changedEvents.append($0) }
        )

        await model.assign(transactionID: Self.candidateID)

        #expect(model.actionFailure == nil)
        #expect(model.event.memberCount == 1)
        #expect(model.event.total == -2000)
        #expect(model.members.map(\.id) == [Self.candidateID])
        #expect(changedEvents.map(\.memberCount) == [1])
    }

    @Test func assignFailureMapsAConflictToTransactionInAnotherEvent() async throws {
        let client = FakeAPIClient()
        await client.setAssignTransactionError(APIError.badStatus(409))
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.assign(transactionID: Self.candidateID)

        #expect(model.actionFailure == .transactionInAnotherEvent)
    }

    @Test func assignFailureMapsAMixedCurrencyRejectionToMixedCurrency() async throws {
        let client = FakeAPIClient()
        await client.setAssignTransactionError(APIError.badStatus(422))
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.assign(transactionID: Self.candidateID)

        #expect(model.actionFailure == .mixedCurrency)
    }

    @Test func assignFailureLeavesEventAndMembersUntouched() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactions([Self.makeTransaction(id: Self.memberID, amount: -5000)])
        await client.setAssignTransactionError(FakeAPIError())
        let model = EventDetailViewModel(event: Self.makeEvent(memberCount: 1, total: -5000), client: client)
        await model.loadMembers()

        await model.assign(transactionID: Self.candidateID)

        #expect(model.actionFailure == .generic)
        #expect(model.event.memberCount == 1)
        #expect(model.members.map(\.id) == [Self.memberID])
    }

    @Test func unassignSuccessRefetchesEventAndMembers() async throws {
        let client = FakeAPIClient()
        await client.setEventTransactions([])
        await client.setEvent(Self.makeEvent(memberCount: 0, total: 0, currency: nil))
        let model = EventDetailViewModel(
            event: Self.makeEvent(memberCount: 1, total: -5000, currency: "EUR"), client: client
        )

        await model.unassign(transactionID: Self.memberID)

        #expect(model.actionFailure == nil)
        #expect(model.event.memberCount == 0)
        #expect(model.members.isEmpty)
        #expect(await client.unassignedEventMembers == [
            FakeAPIClient.RecordedEventMember(eventID: Self.eventID, transactionID: Self.memberID)
        ])
    }

    @Test func closeEventPublishesTheUpdatedStatusAndNotifiesOnEventChange() async throws {
        let client = FakeAPIClient()
        await client.setCloseEventResult(Self.makeEvent(status: .closed))
        var changedEvents: [EventResponse] = []
        let model = EventDetailViewModel(
            event: Self.makeEvent(), client: client, onEventChange: { changedEvents.append($0) }
        )

        await model.closeEvent()

        #expect(model.event.status == .closed)
        #expect(changedEvents.map(\.status) == [.closed])
    }

    @Test func reopenEventPublishesTheUpdatedStatus() async throws {
        let client = FakeAPIClient()
        await client.setReopenEventResult(Self.makeEvent(status: .active))
        let model = EventDetailViewModel(event: Self.makeEvent(status: .closed), client: client)

        await model.reopenEvent()

        #expect(model.event.status == .active)
    }

    @Test func deleteEventSetsWasDeletedAndNotifiesOnEventDeleted() async throws {
        let client = FakeAPIClient()
        var deletedIDs: [UUID] = []
        let model = EventDetailViewModel(
            event: Self.makeEvent(), client: client, onEventDeleted: { deletedIDs.append($0) }
        )

        await model.deleteEvent()

        #expect(model.wasDeleted)
        #expect(model.actionFailure == nil)
        #expect(deletedIDs == [Self.eventID])
        #expect(await client.deletedEventIDs == [Self.eventID])
    }

    @Test func deleteEventFailureLeavesWasDeletedFalse() async throws {
        let client = FakeAPIClient()
        await client.setDeleteEventError(FakeAPIError())
        let model = EventDetailViewModel(event: Self.makeEvent(), client: client)

        await model.deleteEvent()

        #expect(!model.wasDeleted)
        #expect(model.actionFailure == .generic)
    }
}
