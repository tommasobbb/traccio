/// Body for `POST /accounts/{id}/rename`.
///
/// Mirrors the `RenameAccountRequest` schema in `docs/api/openapi.json`.
/// `alias` is mandatory-but-nullable on the backend — `nil` explicitly clears
/// it and falls back to the provider name, rather than being an absent field.
/// A hand-written `encode(to:)` is required for that: Swift's synthesized
/// `Encodable` conformance uses `encodeIfPresent` for an `Optional` stored
/// property, which *omits* the key entirely when the value is `nil` — the
/// wrong shape for a field the backend requires to always be present. Calling
/// `encode(_:forKey:)` directly instead writes an explicit JSON `null`. The
/// backend validates blankness and length; the client does not re-check
/// either.
public struct RenameAccountRequest: Encodable, Sendable {
    /// The new alias, or `nil` to clear it.
    public let alias: String?

    public init(alias: String?) {
        self.alias = alias
    }

    private enum CodingKeys: String, CodingKey {
        case alias
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
    }
}
