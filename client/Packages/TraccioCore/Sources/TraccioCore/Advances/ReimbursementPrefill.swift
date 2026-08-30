extension TraccioCore {
    /// The amount string to seed `AddReimbursementSheet`'s field with when the
    /// user links an incoming transaction as a reimbursement.
    ///
    /// Returns the transaction's magnitude as a plain decimal in the same
    /// no-symbol, no-grouping shape `parseMoneyInput` accepts and the field
    /// otherwise expects a user to type — so linking a movement fills the
    /// amount instead of making the user copy a figure already on screen. A
    /// `nil` transaction (the "contanti" choice) seeds an empty string: a cash
    /// reimbursement has no linked amount to borrow.
    ///
    /// The value is a starting point, not a constraint. `docs/domain.md`
    /// (§Reimbursement) is explicit that a reimbursement amount is never
    /// validated against an expected share — a single transfer may cover two
    /// people's shares, or arrive rounded — so the field stays editable after
    /// this seeds it, and the backend remains the authority on the final
    /// figure. This does no sign inference: the caller passes an already
    /// incoming (`amount > 0`) candidate; the magnitude is taken defensively.
    ///
    /// Parameters
    /// ----------
    /// transaction:
    ///     The candidate the user selected, or `nil` for a cash entry.
    ///
    /// Returns
    /// -------
    /// A `parseMoneyInput`-compatible decimal string (e.g. `"42,00"`), or the
    /// empty string for a `nil` selection.
    public static func reimbursementAmountInput(
        forLinked transaction: TransactionResponse?
    ) -> String {
        guard let transaction else { return "" }
        let magnitude = abs(transaction.amount)
        return String(format: "%d,%02d", magnitude / 100, magnitude % 100)
    }
}
