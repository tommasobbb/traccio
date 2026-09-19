extension TraccioCore {
    /// Divide `total` into `ways` shares as evenly as possible, distributing
    /// the remainder cent-by-cent to the first shares.
    ///
    /// A form-prefill helper for `CreateAdvanceSheet` only — every value it
    /// produces stays editable by the user before the advance is created, and
    /// the advance's authoritative `receivable`/`outstanding` always comes
    /// back from the server afterwards (`docs/engineering.md`: the backend owns
    /// every derived value). This just saves the common "split the dinner
    /// bill N ways" case some typing.
    ///
    /// Parameters
    /// ----------
    /// total:
    ///     The amount to divide, a positive magnitude in minor units (cents).
    /// ways:
    ///     Number of shares; must be `> 0`.
    ///
    /// Returns
    /// -------
    /// `ways` shares summing exactly to `total`, or an empty array if
    /// `ways <= 0`.
    public static func equalSplit(total: Int, ways: Int) -> [Int] {
        guard ways > 0 else { return [] }
        let base = total / ways
        let remainder = total % ways
        return (0..<ways).map { index in base + (index < remainder ? 1 : 0) }
    }
}
