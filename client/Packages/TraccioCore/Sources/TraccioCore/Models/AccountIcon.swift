/// A semantic icon for an account.
///
/// Mirrors the `AccountIcon` schema in `docs/api/openapi.json`. Named for
/// what the account *is*, not for an SF Symbol name — the backend has no
/// notion that SF Symbols exist; the mapping to a concrete symbol lives in
/// `App/Sources/DesignSystem/IconTile.swift`. The raw values match the wire
/// format exactly, so an unknown value fails to decode rather than being
/// silently dropped.
public enum AccountIcon: String, Codable, Sendable, CaseIterable {
    case bank
    case card
    case wallet
    case savings
    case cash
    case phone
}
