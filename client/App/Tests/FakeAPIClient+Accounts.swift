import Foundation
import TraccioCore

/// `AccountsAPI` stub — configurable results, call recording, and the
/// protocol methods themselves, mirroring `APIClient+Accounts.swift`.
extension FakeAPIClient {
    /// A recorded `renameAccount(id:alias:)` call.
    struct RecordedAccountRename: Equatable {
        let id: UUID
        let alias: String?
    }

    /// A recorded `setAccountAppearance(id:color:icon:)` call.
    struct RecordedAccountAppearance: Equatable {
        let id: UUID
        let color: PaletteColor?
        let icon: AccountIcon?
    }

    /// A recorded `setAccountKind(id:kind:)` call (ADR 0029).
    struct RecordedAccountKind: Equatable {
        let id: UUID
        let kind: AccountKind
    }

    /// A recorded `createManualAccount(...)` call (ADR 0020).
    struct RecordedManualAccountCreate: Equatable {
        let alias: String
        let kind: AccountKind
        let currency: String
        let color: PaletteColor?
        let icon: AccountIcon?
    }

    func setAccounts(_ accounts: [AccountResponse]) {
        accountsToReturn = accounts
    }

    func setAccountsError(_ error: Error) {
        accountsError = error
    }

    func setRenameAccountResult(_ account: AccountResponse) {
        renameAccountToReturn = account
    }

    func setRenameAccountError(_ error: Error) {
        renameAccountError = error
    }

    func setAccountAppearanceResult(_ account: AccountResponse) {
        accountAppearanceToReturn = account
    }

    func setAccountAppearanceError(_ error: Error) {
        accountAppearanceError = error
    }

    func setAccountKindResult(_ account: AccountResponse) {
        accountKindToReturn = account
    }

    func setAccountKindError(_ error: Error) {
        accountKindError = error
    }

    func setCreateManualAccountResult(_ account: AccountResponse) {
        createManualAccountToReturn = account
    }

    func setCreateManualAccountError(_ error: Error) {
        createManualAccountError = error
    }

    func setDeleteAccountError(_ error: Error) {
        deleteAccountError = error
    }

    func accounts() async throws -> [AccountResponse] {
        if let accountsError { throw accountsError }
        return accountsToReturn
    }

    func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse {
        if let renameAccountError { throw renameAccountError }
        renamedAccounts.append(RecordedAccountRename(id: id, alias: alias))
        guard let renameAccountToReturn else { throw NotConfigured() }
        return renameAccountToReturn
    }

    func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        if let accountAppearanceError { throw accountAppearanceError }
        accountAppearanceUpdates.append(RecordedAccountAppearance(id: id, color: color, icon: icon))
        guard let accountAppearanceToReturn else { throw NotConfigured() }
        return accountAppearanceToReturn
    }

    func setAccountKind(id: UUID, kind: AccountKind) async throws -> AccountResponse {
        if let accountKindError { throw accountKindError }
        accountKindUpdates.append(RecordedAccountKind(id: id, kind: kind))
        guard let accountKindToReturn else { throw NotConfigured() }
        return accountKindToReturn
    }

    func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        if let createManualAccountError { throw createManualAccountError }
        createdManualAccounts.append(
            RecordedManualAccountCreate(
                alias: alias, kind: kind, currency: currency, color: color, icon: icon
            )
        )
        guard let createManualAccountToReturn else { throw NotConfigured() }
        return createManualAccountToReturn
    }

    func deleteAccount(id: UUID) async throws {
        if let deleteAccountError { throw deleteAccountError }
        deletedAccountIDs.append(id)
    }
}
