import Foundation

/// One ECB reference rate used to build the dashboard's converted total,
/// as returned inside `ConvertedSummaryResponse.rates` (ADR 0021).
///
/// Mirrors the `FxRateResponse` schema in `docs/api/openapi.json`. `rate` is
/// an exact decimal *string* (e.g. `"0.857"`), not a number — the backend
/// never lets a float touch a monetary value and neither does the client;
/// render it as-is or parse it with `Decimal(string:)` if arithmetic is
/// unavoidable (it should not be — the backend already did the conversion).
public struct FxRateResponse: Codable, Sendable, Equatable {
    /// The currency this rate converts *from*.
    public let sourceCurrency: String
    /// The multiplier as an exact decimal string: an amount in
    /// `sourceCurrency` times this yields the base currency.
    public let rate: String
    /// The ECB publication date the rate is for — a movement is converted at
    /// the rate on or before its own date.
    public let rateDate: CalendarDate

    private enum CodingKeys: String, CodingKey {
        case sourceCurrency = "source_currency"
        case rate
        case rateDate = "rate_date"
    }

    public init(sourceCurrency: String, rate: String, rateDate: CalendarDate) {
        self.sourceCurrency = sourceCurrency
        self.rate = rate
        self.rateDate = rateDate
    }
}
