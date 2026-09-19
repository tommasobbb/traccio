import Foundation
import Testing

@testable import TraccioCore

/// Pins the wire spelling of every `CategoryIcon` / `AccountIcon` value
/// against `docs/api/openapi.json` — the models are hand-maintained against
/// the schema (`docs/engineering.md`), so a typo like `phoneBill` instead of
/// `phone_bill` would only surface at runtime without this.
struct CategoryIconWireTests {
    /// Frozen copy of the backend `CategoryIcon` string values (ADR 0017 /
    /// task 5). Kept explicit rather than derived from `allCases`, so a
    /// rename on either side fails this test rather than passing silently.
    private static let categoryWire: Set<String> = [
        "groceries", "dining", "coffee", "takeout", "bakery", "bar",
        "transport", "fuel", "public_transport", "car", "parking", "bike", "train",
        "housing", "rent", "maintenance", "utilities", "furniture", "internet", "phone_bill",
        "health", "pharmacy", "dentist", "fitness", "personal_care",
        "kids", "pets", "education", "books", "gifts",
        "fees", "income", "savings", "investments", "taxes", "insurance", "donations",
        "shopping", "clothing", "electronics", "online_shopping",
        "entertainment", "streaming", "movies", "music", "games", "sports", "hobbies",
        "subscriptions",
        "travel", "hotel", "work", "other",
    ]

    private static let accountWire: Set<String> = [
        "bank", "card", "wallet", "savings", "cash", "phone", "voucher", "investment",
    ]

    @Test func categoryIconRawValuesMatchTheWireContract() {
        #expect(Set(CategoryIcon.allCases.map(\.rawValue)) == Self.categoryWire)
    }

    @Test func accountIconRawValuesMatchTheWireContract() {
        #expect(Set(AccountIcon.allCases.map(\.rawValue)) == Self.accountWire)
    }

    @Test func everyWireValueDecodesAndRoundTrips() throws {
        for value in Self.categoryWire {
            let decoded = try JSONDecoder().decode(CategoryIcon.self, from: Data("\"\(value)\"".utf8))
            #expect(decoded.rawValue == value)
        }
        for value in Self.accountWire {
            let decoded = try JSONDecoder().decode(AccountIcon.self, from: Data("\"\(value)\"".utf8))
            #expect(decoded.rawValue == value)
        }
    }
}
