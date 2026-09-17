extension TraccioCore {
    /// Whether any currency's per-person outstanding sum falls short of its
    /// per-currency total — the sign of reimbursements attributed to no
    /// participant (ADR 0026).
    ///
    /// Pure; every figure in `summary` is server-authoritative (ADR 0026),
    /// this only compares two already-computed sums to decide whether
    /// `AdvancesView` should explain the gap.
    ///
    /// Parameters
    /// ----------
    /// summary:
    ///     The `GET /advances` envelope's cross-advance summary.
    ///
    /// Returns
    /// -------
    /// `true` if some currency's total outstanding exceeds what its
    /// per-person rows account for.
    public static func hasUnattributedReimbursements(_ summary: AdvancesSummaryResponse) -> Bool {
        let personOutstandingByCurrency = Dictionary(
            grouping: summary.byPerson, by: \.currency
        ).mapValues { rows in rows.reduce(0) { $0 + $1.outstanding } }

        return summary.totals.contains { total in
            (personOutstandingByCurrency[total.currency] ?? 0) < total.outstanding
        }
    }
}
