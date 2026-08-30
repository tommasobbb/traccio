/// A semantic icon for a category.
///
/// Mirrors the `CategoryIcon` schema in `docs/api/openapi.json`. Named for
/// what the category *is*, not for an SF Symbol name — same reasoning as
/// `AccountIcon`, and a separate enum from it for the same reason: the two
/// vocabularies are disjoint. The raw values match the wire format exactly,
/// so an unknown value fails to decode rather than being silently dropped.
///
/// The enum is a flat set; the grouped comments below are only for the
/// reader, and the picker's own sectioning lives in the view
/// (`CategoryEditorSheet`), not here — the mapping to a concrete SF Symbol is
/// in `App/Sources/DesignSystem/IconTile.swift`.
public enum CategoryIcon: String, Codable, Sendable, CaseIterable {
    // Food and drink
    case groceries
    case dining
    case coffee
    case takeout
    case bakery
    case bar
    // Transport
    case transport
    case fuel
    case publicTransport = "public_transport"
    case car
    case parking
    case bike
    case train
    // Home
    case housing
    case rent
    case maintenance
    case utilities
    case furniture
    case internet
    case phoneBill = "phone_bill"
    // Health and personal care
    case health
    case pharmacy
    case dentist
    case fitness
    case personalCare = "personal_care"
    // Family
    case kids
    case pets
    case education
    case books
    case gifts
    // Money
    case fees
    case income
    case savings
    case investments
    case taxes
    case insurance
    case donations
    // Shopping
    case shopping
    case clothing
    case electronics
    case onlineShopping = "online_shopping"
    // Leisure
    case entertainment
    case streaming
    case movies
    case music
    case games
    case sports
    case hobbies
    case subscriptions
    // Other
    case travel
    case hotel
    case work
    case other
}
