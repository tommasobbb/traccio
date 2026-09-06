extension TraccioCore {
    /// The structural checks shared by both transfer kinds: different
    /// accounts, shared currency, both still `personal`, neither `rejected`,
    /// non-zero amounts. Mirrors the shared half of `validate_transfer_pair`
    /// (`backend/src/traccio/services/transfers.py`) before its sign-rule
    /// branch. Symmetric in its two arguments.
    private static func sharesTransferStructure(
        _ a: TransactionResponse, _ b: TransactionResponse
    ) -> Bool {
        a.role == .personal && b.role == .personal
            && a.status != .rejected && b.status != .rejected
            && a.amount != 0 && b.amount != 0
            && a.currency == b.currency
            && a.accountID != b.accountID
    }

    /// Whether two transactions may be linked as a **two-sided** transfer via
    /// `POST /transfers/confirm(kind: .twoSided)`.
    ///
    /// Mirrors `validate_transfer_pair(kind=two_sided)` on the fields already
    /// present on `TransactionResponse`. It deliberately does **not**
    /// reproduce the amount tolerance or day window: those bound automatic
    /// *suggestions*, not an explicit user link (`docs/domain.md` §Transfer).
    /// Same posture as `canBecomeAdvance` — a client-side gate for which rows
    /// are selectable, with the backend still the authority (it answers
    /// `422` with a stable reason if a pair slips through).
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
    /// `true` if the pair is structurally valid for a two-sided transfer.
    public static func canLinkAsTransfer(
        _ a: TransactionResponse, _ b: TransactionResponse
    ) -> Bool {
        sharesTransferStructure(a, b) && (a.amount < 0) != (b.amount < 0)
    }

    /// Whether two transactions may be linked as a **funded payment** via
    /// `POST /transfers/confirm(kind: .fundedPayment)` — one outflow funding
    /// another, e.g. a card charge topping up a wallet payment (ADR 0022).
    ///
    /// Mirrors `validate_transfer_pair(kind=funded_payment)`: the same
    /// structural checks as `canLinkAsTransfer`, but **both** legs must be
    /// outflows rather than opposite-signed — unlike a two-sided transfer,
    /// sign alone does not say which leg is the funding one, so the caller
    /// (a confirmation sheet, not this pure check) must ask the user.
    ///
    /// Symmetric in its two arguments.
    ///
    /// Parameters
    /// ----------
    /// a, b:
    ///     The two transactions to check.
    ///
    /// Returns
    /// -------
    /// `true` if the pair is structurally valid for a funded payment.
    public static func canLinkAsFundedPayment(
        _ a: TransactionResponse, _ b: TransactionResponse
    ) -> Bool {
        sharesTransferStructure(a, b) && a.amount < 0 && b.amount < 0
    }
}
