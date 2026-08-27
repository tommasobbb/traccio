import Foundation

/// The dashboard's opt-in combined total, every currency converted into one
/// base currency (ADR 0021).
///
/// Mirrors the `ConvertedSummaryResponse` schema in `docs/api/openapi.json`.
/// Present on `DashboardSummaryResponse.converted` only when the backend has
/// FX enabled *and* every currency in the period could be converted;
/// otherwise `converted` is `nil` and `conversionUnavailable` says why. It
/// is **additive** — the per-currency `currencies` breakdown is unchanged and
/// remains the source of truth.
public struct ConvertedSummaryResponse: Codable, Sendable, Equatable {
    /// A normal currency summary whose `currency` is the base currency and
    /// whose totals sum every movement, each converted at its own date's
    /// rate. `byCategory`/`byBucket`/`byAccount`/`comparison` are converted
    /// too, so a screen can render its usual breakdown from this directly.
    public let summary: CurrencySummaryResponse
    /// The distinct (source currency, rate, date) triples used, for a
    /// provenance caption.
    public let rates: [FxRateResponse]
    /// Always `"historical"` — each movement converted at the rate for its
    /// own effective date.
    public let basis: String

    public init(summary: CurrencySummaryResponse, rates: [FxRateResponse], basis: String) {
        self.summary = summary
        self.rates = rates
        self.basis = basis
    }
}
