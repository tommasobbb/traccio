/// A semantic icon for a category.
///
/// Mirrors the `CategoryIcon` schema in `docs/api/openapi.json`. Named for
/// what the category *is*, not for an SF Symbol name — same reasoning as
/// `AccountIcon`, and a separate enum from it for the same reason: the two
/// vocabularies are disjoint. The raw values match the wire format exactly,
/// so an unknown value fails to decode rather than being silently dropped.
public enum CategoryIcon: String, Codable, Sendable, CaseIterable {
    case groceries
    case dining
    case coffee
    case takeout
    case transport
    case fuel
    case publicTransport = "public_transport"
    case housing
    case rent
    case maintenance
    case utilities
    case health
    case shopping
    case clothing
    case electronics
    case entertainment
    case streaming
    case movies
    case travel
    case subscriptions
    case fees
    case income
    case other
}
