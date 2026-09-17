import Foundation
import TraccioCore

/// `TransfersAPI` stub, mirroring `APIClient+Transfers.swift`.
extension FakeAPIClient {
    /// A recorded `outgoingID`/`incomingID` pair, for asserting exactly which
    /// legs a confirm/reject call named.
    struct RecordedTransferPair: Equatable {
        let outgoingID: UUID
        let incomingID: UUID
        var kind: TransferKind = .twoSided
    }

    func setTransferSuggestions(_ suggestions: [TransferSuggestionResponse]) {
        transferSuggestionsToReturn = suggestions
    }

    func setTransferSuggestionsError(_ error: Error) {
        transferSuggestionsError = error
    }

    func setTransfers(_ transfers: [TransferResponse]) {
        transfersToReturn = transfers
    }

    func setConfirmTransferResult(_ transfer: TransferResponse) {
        confirmTransferToReturn = transfer
    }

    func setConfirmTransferError(_ error: Error) {
        confirmTransferError = error
    }

    func setRejectTransferError(_ error: Error) {
        rejectTransferError = error
    }

    func setDeleteTransferError(_ error: Error) {
        deleteTransferError = error
    }

    func transferSuggestions() async throws -> [TransferSuggestionResponse] {
        transferSuggestionsFetchCount += 1
        if let transferSuggestionsError { throw transferSuggestionsError }
        return transferSuggestionsToReturn
    }

    func transfers() async throws -> [TransferResponse] {
        transfersToReturn
    }

    func confirmTransfer(
        outgoingID: UUID, incomingID: UUID, kind: TransferKind
    ) async throws -> TransferResponse {
        if let confirmTransferError { throw confirmTransferError }
        confirmedTransferPairs.append(
            RecordedTransferPair(outgoingID: outgoingID, incomingID: incomingID, kind: kind)
        )
        guard let confirmTransferToReturn else { throw NotConfigured() }
        return confirmTransferToReturn
    }

    func rejectTransfer(outgoingID: UUID, incomingID: UUID) async throws {
        if let rejectTransferError { throw rejectTransferError }
        rejectedTransferPairs.append(RecordedTransferPair(outgoingID: outgoingID, incomingID: incomingID))
    }

    func deleteTransfer(id: UUID) async throws {
        if let deleteTransferError { throw deleteTransferError }
        deletedTransferIDs.append(id)
    }
}
