/// A semantic colour, shared by an account and a category.
///
/// Mirrors the `PaletteColor` schema in `docs/api/openapi.json`. A fixed
/// vocabulary rather than a free hex string — see ADR 0017 — so the raw
/// values match the wire format exactly and an unknown value fails to decode
/// rather than being silently dropped or defaulted.
public enum PaletteColor: String, Codable, Sendable, CaseIterable {
    case blue
    case indigo
    case purple
    case pink
    case red
    case orange
    case amber
    case green
    case teal
    /// The neutral default for anything the user has not deliberately
    /// coloured yet.
    case slate
}
