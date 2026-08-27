import Foundation

/// Body for `POST /accounts` — create a manual account (ADR 0020).
///
/// Mirrors the `CreateManualAccountRequest` schema in `docs/api/openapi.json`.
/// `CodingKeys` spell the wire name explicitly, following every other request
/// model's convention (`CreateEventRequest`, `CreateAdvanceRequest`) rather
/// than an encoder-wide case strategy.
public struct CreateManualAccountRequest: Encodable, Sendable {
    /// The account's name, e.g. `"Contanti"`. A manual account must have one
    /// (unlike a synced account, which falls back to the provider name); the
    /// backend answers `422` for a blank or over-long value.
    public let alias: String
    /// What type of account it is — typically `.cash` or `.wallet` for a
    /// manual one, but any kind is accepted.
    public let kind: AccountKind
    /// The account's ISO 4217 currency (three uppercase letters).
    public let currency: String
    /// Optional colour.
    public let color: PaletteColor?
    /// Optional icon.
    public let icon: AccountIcon?

    private enum CodingKeys: String, CodingKey {
        case alias
        case kind
        case currency
        case color
        case icon
    }

    public init(
        alias: String,
        kind: AccountKind,
        currency: String,
        color: PaletteColor? = nil,
        icon: AccountIcon? = nil
    ) {
        self.alias = alias
        self.kind = kind
        self.currency = currency
        self.color = color
        self.icon = icon
    }
}
