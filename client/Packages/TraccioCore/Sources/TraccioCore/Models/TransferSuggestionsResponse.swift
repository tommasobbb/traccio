/// Envelope for the `GET /transfers/suggestions` list.
///
/// Mirrors the `TransferSuggestionsResponse` schema in
/// `docs/api/openapi.json`. A wrapper object rather than a bare array leaves
/// room for metadata later without breaking decoding — same reasoning as
/// `AccountsResponse`.
public struct TransferSuggestionsResponse: Codable, Sendable {
    /// The suggested transfers, most confident first.
    public let suggestions: [TransferSuggestionResponse]

    public init(suggestions: [TransferSuggestionResponse]) {
        self.suggestions = suggestions
    }
}
