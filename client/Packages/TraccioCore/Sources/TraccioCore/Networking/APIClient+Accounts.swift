import Foundation

// Account endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Fetch the caller's accounts, oldest first.
    ///
    /// Returns
    /// -------
    /// The decoded accounts from `GET /accounts`.
    public func accounts() async throws -> [AccountResponse] {
        let envelope: AccountsResponse = try await get("accounts")
        return envelope.accounts
    }

    /// Set or clear an account's alias.
    ///
    /// Mirrors `POST /accounts/{id}/rename`, `200` with the account under its
    /// new alias. A `404` if the account is unknown or not the caller's; a
    /// `422` if the alias is blank (pass `nil` to clear it instead) or too
    /// long — the client does not pre-check either.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to rename.
    /// alias:
    ///     The new alias, or `nil` to clear it and fall back to the provider
    ///     name.
    ///
    /// Returns
    /// -------
    /// The account under its new alias.
    public func renameAccount(id: UUID, alias: String?) async throws -> AccountResponse {
        try await post("accounts/\(id.uuidString)/rename", body: RenameAccountRequest(alias: alias))
    }

    /// Set an account's colour and icon.
    ///
    /// Mirrors `POST /accounts/{id}/appearance`, `200` with the account under
    /// its new appearance. A full replace: both fields are sent together. A
    /// `404` if the account is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to restyle.
    /// color:
    ///     The new colour, or `nil` to clear it.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    ///
    /// Returns
    /// -------
    /// The account under its new appearance.
    public func setAccountAppearance(
        id: UUID, color: PaletteColor?, icon: AccountIcon?
    ) async throws -> AccountResponse {
        try await post(
            "accounts/\(id.uuidString)/appearance",
            body: SetAccountAppearanceRequest(color: color, icon: icon)
        )
    }

    /// Create a manual account — one with no bank behind it (ADR 0020).
    ///
    /// Mirrors `POST /accounts`, `201` with the created account (its
    /// `connectionID` is `nil`, its `source` is `.manual`). A `422` if the
    /// alias is blank or too long, or the currency/kind is not recognized —
    /// the client does not pre-check.
    ///
    /// Parameters
    /// ----------
    /// alias:
    ///     The account's name (e.g. "Contanti").
    /// kind:
    ///     What type of account it is — typically `.cash` or `.wallet`.
    /// currency:
    ///     The account's ISO 4217 currency.
    /// color:
    ///     Optional colour.
    /// icon:
    ///     Optional icon.
    ///
    /// Returns
    /// -------
    /// The created manual account.
    public func createManualAccount(
        alias: String, kind: AccountKind, currency: String,
        color: PaletteColor? = nil, icon: AccountIcon? = nil
    ) async throws -> AccountResponse {
        try await post(
            "accounts",
            body: CreateManualAccountRequest(
                alias: alias, kind: kind, currency: currency, color: color, icon: icon
            )
        )
    }

    /// Delete a manual account (ADR 0020).
    ///
    /// Mirrors `DELETE /accounts/{id}`, `204`. A `404` if the account is
    /// unknown or not the caller's; a `409 account_not_manual` if it is a
    /// synced account (removed only by the connection flow); a `409
    /// account_not_empty` if it still holds a transaction — delete those
    /// first. `APIError.badStatus(409)` does not distinguish the two `409`s;
    /// the caller checks whether the account is empty before offering this.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The account to delete.
    public func deleteAccount(id: UUID) async throws {
        try await delete("accounts/\(id.uuidString)")
    }
}
