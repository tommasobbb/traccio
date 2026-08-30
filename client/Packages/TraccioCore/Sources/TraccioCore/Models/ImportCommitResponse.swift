import Foundation

/// Result of `POST /imports/commit` (ADR 0023): how the insert went.
///
/// Mirrors the `ImportCommitResponse` schema in `docs/api/openapi.json`.
/// Running the same file twice inserts nothing the second time (`imported ==
/// 0`, `skipped` covers every movement).
public struct ImportCommitResponse: Codable, Sendable, Equatable {
    /// Movements inserted.
    public let imported: Int
    /// Movements whose key was already stored, left untouched.
    public let skipped: Int
    /// Source rows that produced no movement.
    public let invalid: Int

    public init(imported: Int, skipped: Int, invalid: Int) {
        self.imported = imported
        self.skipped = skipped
        self.invalid = invalid
    }
}
