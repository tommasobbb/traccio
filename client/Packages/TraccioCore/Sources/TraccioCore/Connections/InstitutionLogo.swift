import Foundation

extension TraccioCore {
    /// A resized variant of a bank logo URL for display at `width` points.
    ///
    /// Enable Banking's ASPSP `logo` URL (`https://enablebanking.com/brands/
    /// {country}/{name}/`) accepts uploadcare-style transformation suffixes;
    /// `-/resize/{px}x/` returns a width-constrained WebP a couple of KB in
    /// size instead of the multi-megapixel PNG. This appends that suffix,
    /// scaling `width` by `scale` (pass the display's scale for a crisp
    /// image) — the base URL always ends in `/`, so the suffix concatenates
    /// directly.
    ///
    /// Returns `nil` for a `nil`/blank base, one that is not an `http(s)`
    /// URL, or one that fails to parse after the suffix is appended — so a
    /// caller can fall back to a lettermark.
    ///
    /// Parameters
    /// ----------
    /// base:
    ///     The raw `logo` URL from `InstitutionResponse`/`ConnectionResponse`.
    /// width:
    ///     Target width in points.
    /// scale:
    ///     Display scale to multiply `width` by (default `3`, the densest
    ///     current iPhone). Clamped to at least `1`.
    ///
    /// Returns
    /// -------
    /// The transformed URL, or `nil` if `base` is unusable.
    public static func institutionLogoURL(
        _ base: String?, width: Int, scale: CGFloat = 3
    ) -> URL? {
        guard let base else { return nil }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        let pixels = max(1, Int((CGFloat(width) * max(1, scale)).rounded()))
        let separator = trimmed.hasSuffix("/") ? "" : "/"
        return URL(string: "\(trimmed)\(separator)-/resize/\(pixels)x/")
    }
}
