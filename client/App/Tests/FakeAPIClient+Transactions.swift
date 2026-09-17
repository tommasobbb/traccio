import Foundation
import TraccioCore

/// `TransactionsAPI` stub, mirroring `APIClient+Transactions.swift`.
extension FakeAPIClient {
    /// A recorded `createManualTransaction(_:)` call (ADR 0020).
    struct RecordedManualTransactionCreate: Equatable {
        let accountID: UUID
        let amount: Int
        let currency: String
        let valueDate: Date
        let description: String
        let confirmedCategoryID: UUID?
    }

    /// A recorded `editManualTransaction(id:_:)` call (ADR 0020).
    struct RecordedManualTransactionEdit: Equatable {
        let id: UUID
        let amount: Int
        let currency: String
        let valueDate: Date
        let description: String
    }

    func setTransaction(_ transaction: TransactionResponse) {
        transactionToReturn = transaction
    }

    func setTransactionError(_ error: Error) {
        transactionError = error
    }

    func setConfirmCategoryError(_ error: Error) {
        confirmCategoryError = error
    }

    func setClearCategoryError(_ error: Error) {
        clearCategoryError = error
    }

    func setTransactions(_ transactions: [TransactionResponse]) {
        transactionsToReturn = transactions
    }

    /// Configure `transaction(id:)`'s answer for one specific id, distinct
    /// from the catch-all `setTransaction(_:)`. Needed wherever a test fetches
    /// two different rows by id (both legs of a transfer).
    func setTransaction(_ transaction: TransactionResponse, forID id: UUID) {
        transactionsByID[id] = transaction
    }

    func setCreateManualTransactionResult(_ transaction: TransactionResponse) {
        createManualTransactionToReturn = transaction
    }

    func setCreateManualTransactionError(_ error: Error) {
        createManualTransactionError = error
    }

    func setEditManualTransactionResult(_ transaction: TransactionResponse) {
        editManualTransactionToReturn = transaction
    }

    func setEditManualTransactionError(_ error: Error) {
        editManualTransactionError = error
    }

    func setDeleteManualTransactionError(_ error: Error) {
        deleteManualTransactionError = error
    }

    func transaction(id: UUID) async throws -> TransactionResponse {
        transactionFetchCount += 1
        if let transactionError { throw transactionError }
        if let byID = transactionsByID[id] { return byID }
        guard let transactionToReturn else { throw NotConfigured() }
        return transactionToReturn
    }

    func confirmCategory(transactionID: UUID, categoryID: UUID) async throws {
        if let confirmCategoryError { throw confirmCategoryError }
        confirmedCategoryIDs.append(categoryID)
    }

    func clearCategory(transactionID: UUID) async throws {
        if let clearCategoryError { throw clearCategoryError }
        clearCategoryCallCount += 1
    }

    func createManualTransaction(
        _ request: CreateManualTransactionRequest
    ) async throws -> TransactionResponse {
        if let createManualTransactionError { throw createManualTransactionError }
        createdManualTransactions.append(
            RecordedManualTransactionCreate(
                accountID: request.accountID,
                amount: request.amount,
                currency: request.currency,
                valueDate: request.valueDate,
                description: request.description,
                confirmedCategoryID: request.confirmedCategoryID
            )
        )
        guard let createManualTransactionToReturn else { throw NotConfigured() }
        return createManualTransactionToReturn
    }

    func editManualTransaction(
        id: UUID, _ request: EditManualTransactionRequest
    ) async throws -> TransactionResponse {
        if let editManualTransactionError { throw editManualTransactionError }
        editedManualTransactions.append(
            RecordedManualTransactionEdit(
                id: id,
                amount: request.amount,
                currency: request.currency,
                valueDate: request.valueDate,
                description: request.description
            )
        )
        guard let editManualTransactionToReturn else { throw NotConfigured() }
        return editManualTransactionToReturn
    }

    func deleteManualTransaction(id: UUID) async throws {
        if let deleteManualTransactionError { throw deleteManualTransactionError }
        deletedManualTransactionIDs.append(id)
    }

    func transactions(filter: TransactionFilter, limit: Int, offset: Int) async throws
        -> [TransactionResponse]
    {
        receivedTransactionsFilters.append(filter)
        receivedTransactionsOffsets.append(offset)
        return transactionsToReturn
    }
}
