/// Body for `POST /accounts/{id}/kind` (ADR 0029).
///
/// Mirrors the `SetAccountKindRequest` schema in `docs/api/openapi.json`.
/// The only way to reclassify an existing manual account (e.g. Contanti →
/// Buoni pasto) without deleting and recreating it.
public struct SetAccountKindRequest: Encodable, Sendable {
    /// The new kind.
    public let kind: AccountKind

    public init(kind: AccountKind) {
        self.kind = kind
    }
}
