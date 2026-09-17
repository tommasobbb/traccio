import Foundation
import TraccioCore

/// `EventsAPI` stub, mirroring `APIClient+Events.swift`.
extension FakeAPIClient {
    /// A recorded `eventID`/`transactionID` pair, for asserting exactly which
    /// event and transaction an assign/unassign call named.
    struct RecordedEventMember: Equatable {
        let eventID: UUID
        let transactionID: UUID
    }

    func setEvents(_ events: [EventResponse]) {
        eventsToReturn = events
    }

    func setEventsError(_ error: Error) {
        eventsError = error
    }

    func setEvent(_ event: EventResponse) {
        eventToReturn = event
    }

    func setEventError(_ error: Error) {
        eventError = error
    }

    func setEventTransactions(_ transactions: [TransactionResponse]) {
        eventTransactionsToReturn = transactions
    }

    func setEventTransactionsError(_ error: Error) {
        eventTransactionsError = error
    }

    func setEventSummary(_ summary: EventSummaryResponse) {
        eventSummaryToReturn = summary
    }

    func setEventSummaryError(_ error: Error) {
        eventSummaryError = error
    }

    func setEventSuggestions(_ transactions: [TransactionResponse]) {
        eventSuggestionsToReturn = transactions
    }

    func setEventSuggestionsError(_ error: Error) {
        eventSuggestionsError = error
    }

    func setCreateEventResult(_ event: EventResponse) {
        createEventToReturn = event
    }

    func setCreateEventError(_ error: Error) {
        createEventError = error
    }

    func setUpdateEventResult(_ event: EventResponse) {
        updateEventToReturn = event
    }

    func setUpdateEventError(_ error: Error) {
        updateEventError = error
    }

    func setDeleteEventError(_ error: Error) {
        deleteEventError = error
    }

    func setCloseEventResult(_ event: EventResponse) {
        closeEventToReturn = event
    }

    func setCloseEventError(_ error: Error) {
        closeEventError = error
    }

    func setReopenEventResult(_ event: EventResponse) {
        reopenEventToReturn = event
    }

    func setReopenEventError(_ error: Error) {
        reopenEventError = error
    }

    func setAssignTransactionError(_ error: Error) {
        assignTransactionError = error
    }

    func setUnassignTransactionError(_ error: Error) {
        unassignTransactionError = error
    }

    func events() async throws -> [EventResponse] {
        eventsFetchCount += 1
        if let eventsError { throw eventsError }
        return eventsToReturn
    }

    func event(id: UUID) async throws -> EventResponse {
        eventFetchCount += 1
        if let eventError { throw eventError }
        guard let eventToReturn else { throw NotConfigured() }
        return eventToReturn
    }

    func eventTransactions(id: UUID) async throws -> [TransactionResponse] {
        eventTransactionsFetchCount += 1
        if let eventTransactionsError { throw eventTransactionsError }
        return eventTransactionsToReturn
    }

    func eventSummary(id: UUID) async throws -> EventSummaryResponse {
        eventSummaryFetchCount += 1
        if let eventSummaryError { throw eventSummaryError }
        guard let eventSummaryToReturn else { throw NotConfigured() }
        return eventSummaryToReturn
    }

    func eventSuggestions(id: UUID) async throws -> [TransactionResponse] {
        eventSuggestionsFetchCount += 1
        if let eventSuggestionsError { throw eventSuggestionsError }
        return eventSuggestionsToReturn
    }

    func createEvent(_ request: CreateEventRequest) async throws -> EventResponse {
        if let createEventError { throw createEventError }
        createdEventRequests.append(request)
        guard let createEventToReturn else { throw NotConfigured() }
        return createEventToReturn
    }

    func updateEvent(id: UUID, _ request: UpdateEventRequest) async throws -> EventResponse {
        if let updateEventError { throw updateEventError }
        updatedEventRequests.append((id, request))
        guard let updateEventToReturn else { throw NotConfigured() }
        return updateEventToReturn
    }

    func deleteEvent(id: UUID) async throws {
        if let deleteEventError { throw deleteEventError }
        deletedEventIDs.append(id)
    }

    func closeEvent(id: UUID) async throws -> EventResponse {
        closeEventCallCount += 1
        if let closeEventError { throw closeEventError }
        guard let closeEventToReturn else { throw NotConfigured() }
        return closeEventToReturn
    }

    func reopenEvent(id: UUID) async throws -> EventResponse {
        reopenEventCallCount += 1
        if let reopenEventError { throw reopenEventError }
        guard let reopenEventToReturn else { throw NotConfigured() }
        return reopenEventToReturn
    }

    func assignTransaction(eventID: UUID, transactionID: UUID) async throws {
        if let assignTransactionError { throw assignTransactionError }
        assignedEventMembers.append(RecordedEventMember(eventID: eventID, transactionID: transactionID))
    }

    func unassignTransaction(eventID: UUID, transactionID: UUID) async throws {
        if let unassignTransactionError { throw unassignTransactionError }
        unassignedEventMembers.append(RecordedEventMember(eventID: eventID, transactionID: transactionID))
    }
}
