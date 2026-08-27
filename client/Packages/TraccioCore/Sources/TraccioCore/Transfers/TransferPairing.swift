extension TraccioCore {
    /// Whether two transactions may be linked as a transfer via
    /// `POST /transfers/confirm`.
    ///
    /// Mirrors `validate_transfer_pair`
    /// (`backend/src/traccio/services/transfers.py`) on the fields already
    /// present on `TransactionResponse` — `role`, `status`, `amount`,
    /// `currency`, `accountID`. It deliberately does **not** reproduce the
    /// amount tolerance or day window: those bound automatic *suggestions*,
    /// not an explicit user link (`docs/domain.md` §Transfer). Same posture
    /// as `canBecomeAdvance` — a client-side gate for which rows are
    /// selectable, with the backend still the authority (it answers `422`
    /// with a stable reason if a pair slips through).
    ///
    /// Symmetric in its two arguments: the caller decides which leg is
    /// outgoing (the negative one) when calling the endpoint.
    ///
    /// Parameters
    /// ----------
    /// a, b:
    ///     The two transactions to check.
    ///
    /// Returns
    /// -------
    /// `true` if the pair is structurally valid for a transfer.
    public static func canLinkAsTransfer(
        _ a: TransactionResponse, _ b: TransactionResponse
    ) -> Bool {
        a.role == .personal && b.role == .personal
            && a.status != .rejected && b.status != .rejected
            && a.amount != 0 && b.amount != 0
            && a.currency == b.currency
            && a.accountID != b.accountID
            && (a.amount < 0) != (b.amount < 0)
    }
}
