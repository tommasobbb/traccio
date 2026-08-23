import Foundation

extension TraccioCore {
    /// Format a minor-units amount and an ISO 4217 currency code for display.
    ///
    /// The only place minor units become a display string — every screen
    /// showing an amount goes through this, never a bespoke `String(format:)`.
    /// This does no arithmetic and no sign inference beyond what `amount`
    /// already carries: the backend, not the client, decides what a figure
    /// means (`docs/architecture.md`).
    ///
    /// Parameters
    /// ----------
    /// amount:
    ///     The value in minor units (cents), signed or unsigned as-is.
    /// currencyCode:
    ///     An ISO 4217 code (e.g. `"EUR"`). An unrecognised code (e.g. the
    ///     `"XXX"` Traccio uses for a currency-agnostic wallet) still formats,
    ///     falling back to a plain minor-units decimal with the code appended.
    /// explicitSign:
    ///     When `true`, a positive amount is prefixed with `+` (used for
    ///     income and net figures); zero is never signed. Defaults to `false`.
    ///
    /// Returns
    /// -------
    /// A localized, currency-formatted string, e.g. `"€1.240,50"` or
    /// `"+€2.100,00"`.
    public static func formatMoney(
        amount: Int,
        currencyCode: String,
        explicitSign: Bool = false
    ) -> String {
        let decimal = Decimal(amount) / 100

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        // NumberFormatter silently falls back to a locale-default currency
        // symbol when it doesn't recognize `currencyCode` (e.g. "XXX"); guard
        // that by checking whether the locale actually knows this code and,
        // if not, using a plain decimal with the code appended instead.
        let formatted: String
        if Locale.commonISOCurrencyCodes.contains(currencyCode.uppercased()),
            let currencyFormatted = formatter.string(from: decimal as NSDecimalNumber)
        {
            formatted = currencyFormatted
        } else {
            let plain = NumberFormatter()
            plain.numberStyle = .decimal
            plain.minimumFractionDigits = 2
            plain.maximumFractionDigits = 2
            let number = plain.string(from: decimal as NSDecimalNumber) ?? "\(decimal)"
            formatted = "\(number) \(currencyCode)"
        }

        guard explicitSign, amount > 0 else { return formatted }
        return "+\(formatted)"
    }

    /// Parse a user-typed decimal amount into minor units (cents).
    ///
    /// The inverse counterpart to `formatMoney`, for a plain currency input
    /// field with no currency symbol or thousands separator — just digits and
    /// one decimal separator. Accepts both `.` and `,` since Traccio's UI is
    /// Italian-first but the device's decimal separator may be either. This
    /// is UI-input parsing, not a financial derivation: the backend still
    /// validates and is the final authority on whether the resulting amount
    /// is acceptable (e.g. `own_share` in range), answering `422` if not.
    ///
    /// Parameters
    /// ----------
    /// text:
    ///     The raw field contents.
    ///
    /// Returns
    /// -------
    /// The amount in cents, or `nil` for empty, malformed, or negative input.
    public static func parseMoneyInput(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }
}
