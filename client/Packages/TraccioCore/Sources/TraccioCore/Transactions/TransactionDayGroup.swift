import Foundation

/// A run of transactions sharing the same calendar day, as produced by
/// `groupByDay(_:calendar:)`.
///
/// `day` is the start-of-day `Date` for the group, or `nil` for the single
/// trailing group of transactions with no `effectiveDate` at all — the
/// backend's ordering leaves those unordered relative to each other, so they
/// are grouped together rather than interleaved.
public struct TransactionDayGroup: Sendable, Equatable {
    public let day: Date?
    public let transactions: [TransactionResponse]

    public init(day: Date?, transactions: [TransactionResponse]) {
        self.day = day
        self.transactions = transactions
    }
}

extension TraccioCore {
    /// Group already-ordered transactions into consecutive same-day runs.
    ///
    /// Pure and order-preserving: it does not sort — `transactions` is
    /// expected in the order `GET /transactions` returns (most recent
    /// first) — it only collapses consecutive rows that fall on the same
    /// calendar day into one `TransactionDayGroup`. A transaction with no
    /// `effectiveDate` is deferred to a single trailing `day == nil` group
    /// rather than breaking up the surrounding dated runs.
    ///
    /// Parameters
    /// ----------
    /// transactions:
    ///     Transactions in display order.
    /// calendar:
    ///     Calendar used to compute "start of day". Defaults to the current
    ///     calendar so a group boundary matches what the user sees on the
    ///     device's clock.
    ///
    /// Returns
    /// -------
    /// One group per consecutive run of same-day transactions, in input
    /// order, followed by the no-date group (if any) last.
    public static func groupByDay(
        _ transactions: [TransactionResponse],
        calendar: Calendar = .current
    ) -> [TransactionDayGroup] {
        var dated: [TransactionDayGroup] = []
        var undated: [TransactionResponse] = []

        for transaction in transactions {
            guard let date = transaction.effectiveDate else {
                undated.append(transaction)
                continue
            }
            let day = calendar.startOfDay(for: date)
            if let last = dated.last, last.day == day {
                dated[dated.count - 1] = TransactionDayGroup(
                    day: day, transactions: last.transactions + [transaction]
                )
            } else {
                dated.append(TransactionDayGroup(day: day, transactions: [transaction]))
            }
        }

        if !undated.isEmpty {
            dated.append(TransactionDayGroup(day: nil, transactions: undated))
        }
        return dated
    }
}
