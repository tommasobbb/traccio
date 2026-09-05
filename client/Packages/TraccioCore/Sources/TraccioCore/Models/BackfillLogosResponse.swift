import Foundation

/// Result of `POST /connections/backfill-logos`.
///
/// Mirrors the `BackfillLogosResponse` schema in `docs/api/openapi.json`. The
/// endpoint fills `institution_logo` for connections authorized before that
/// column existed (they otherwise fall back to a lettermark). Idempotent: a
/// connection that already has a logo, has no stored country, or matches no
/// provider institution is left untouched.
public struct BackfillLogosResponse: Codable, Sendable, Equatable {
    /// How many connections gained a logo this call. `0` when there was
    /// nothing to do.
    public let updated: Int

    public init(updated: Int) {
        self.updated = updated
    }
}
