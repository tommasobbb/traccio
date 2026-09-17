import Foundation
import TraccioCore

/// `AdvancesAPI` stub, mirroring `APIClient+Advances.swift`.
extension FakeAPIClient {
    func setAdvance(_ advance: AdvanceResponse) {
        advanceToReturn = advance
    }

    func setAdvanceError(_ error: Error) {
        advanceError = error
    }

    func setAdvances(_ advances: [AdvanceResponse]) {
        advancesToReturn = advances
    }

    func setAdvancesSummary(_ summary: AdvancesSummaryResponse) {
        advancesSummaryToReturn = summary
    }

    func setAdvancesError(_ error: Error) {
        advancesError = error
    }

    func setCreateAdvanceResult(_ advance: AdvanceResponse) {
        createAdvanceToReturn = advance
    }

    func setCreateAdvanceError(_ error: Error) {
        createAdvanceError = error
    }

    func setDeleteAdvanceError(_ error: Error) {
        deleteAdvanceError = error
    }

    func setWriteOffAdvanceResult(_ advance: AdvanceResponse) {
        writeOffAdvanceToReturn = advance
    }

    func setWriteOffAdvanceError(_ error: Error) {
        writeOffAdvanceError = error
    }

    func setReopenAdvanceResult(_ advance: AdvanceResponse) {
        reopenAdvanceToReturn = advance
    }

    func setReopenAdvanceError(_ error: Error) {
        reopenAdvanceError = error
    }

    func setCreateReimbursementResult(_ reimbursement: ReimbursementResponse) {
        createReimbursementToReturn = reimbursement
    }

    func setCreateReimbursementError(_ error: Error) {
        createReimbursementError = error
    }

    func setDeleteReimbursementError(_ error: Error) {
        deleteReimbursementError = error
    }

    func setReimbursements(_ reimbursements: [ReimbursementResponse]) {
        reimbursementsToReturn = reimbursements
    }

    func setReimbursementsError(_ error: Error) {
        reimbursementsError = error
    }

    func advances(status: AdvanceStatus?) async throws -> AdvancesResponse {
        lastAdvancesStatus = .some(status)
        if let advancesError { throw advancesError }
        let rows = status.map { wanted in advancesToReturn.filter { $0.status == wanted } }
            ?? advancesToReturn
        return AdvancesResponse(advances: rows, summary: advancesSummaryToReturn)
    }

    func advance(id: UUID) async throws -> AdvanceResponse {
        if let advanceError { throw advanceError }
        guard let advanceToReturn else { throw NotConfigured() }
        return advanceToReturn
    }

    func createAdvance(_ request: CreateAdvanceRequest) async throws -> AdvanceResponse {
        if let createAdvanceError { throw createAdvanceError }
        createdAdvanceRequests.append(request)
        guard let createAdvanceToReturn else { throw NotConfigured() }
        return createAdvanceToReturn
    }

    func deleteAdvance(id: UUID) async throws {
        if let deleteAdvanceError { throw deleteAdvanceError }
        deletedAdvanceIDs.append(id)
    }

    func writeOffAdvance(id: UUID) async throws -> AdvanceResponse {
        writeOffAdvanceCallCount += 1
        if let writeOffAdvanceError { throw writeOffAdvanceError }
        guard let writeOffAdvanceToReturn else { throw NotConfigured() }
        return writeOffAdvanceToReturn
    }

    func reopenAdvance(id: UUID) async throws -> AdvanceResponse {
        reopenAdvanceCallCount += 1
        if let reopenAdvanceError { throw reopenAdvanceError }
        guard let reopenAdvanceToReturn else { throw NotConfigured() }
        return reopenAdvanceToReturn
    }

    func createReimbursement(
        advanceID: UUID, _ request: CreateReimbursementRequest
    ) async throws -> ReimbursementResponse {
        if let createReimbursementError { throw createReimbursementError }
        createdReimbursementRequests.append(request)
        guard let createReimbursementToReturn else { throw NotConfigured() }
        return createReimbursementToReturn
    }

    func reimbursements(advanceID: UUID) async throws -> [ReimbursementResponse] {
        if let reimbursementsError { throw reimbursementsError }
        return reimbursementsToReturn
    }

    func deleteReimbursement(advanceID: UUID, id: UUID) async throws {
        if let deleteReimbursementError { throw deleteReimbursementError }
        deletedReimbursementIDs.append(id)
    }
}
