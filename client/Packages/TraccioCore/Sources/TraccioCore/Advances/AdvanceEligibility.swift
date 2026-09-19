extension TraccioCore {
    /// Whether `transaction` may become an advance via `POST /advances`.
    ///
    /// Mirrors the three preconditions of `validate_advance`
    /// (`backend/src/traccio/domain/advances.py`) that depend only on fields
    /// already present on `TransactionResponse`: `role == .personal`, an
    /// outgoing amount, and not `rejected`. This decides only whether to show
    /// the "Segna come anticipo" action — the `own_share` range check is not
    /// duplicated here and stays entirely server-side, which answers `422`
    /// with a stable, value-free reason if the declared share is out of
    /// range (`docs/engineering.md`: never a value in an error).
    ///
    /// Parameters
    /// ----------
    /// transaction:
    ///     The transaction to check.
    ///
    /// Returns
    /// -------
    /// `true` if the transaction is eligible to become an advance.
    public static func canBecomeAdvance(_ transaction: TransactionResponse) -> Bool {
        transaction.role == .personal && transaction.amount < 0 && transaction.status != .rejected
    }
}
