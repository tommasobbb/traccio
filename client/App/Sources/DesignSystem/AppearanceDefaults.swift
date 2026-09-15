import TraccioCore

/// Fallback appearance for a row that has no explicit icon/colour chosen yet
/// (ADR 0017/0018 make both optional on an account, icon-only on a category —
/// a category always carries a colour, seeded on creation).
///
/// Lifted out of `AccountsView` (previously a private `defaultIcon(for:)`) so
/// `TransactionRow` can render the same fallback rather than leaving its
/// leading tile blank whenever appearance was never set.
extension AccountIcon {
    /// The icon a bare `AccountKind` renders with before the user picks one
    /// of their own — pulled out of `AccountResponse.tileIcon` so the "Tipo"
    /// pickers (`CreateManualAccountSheet`, `AccountEditorSheet`) can show
    /// the same icon next to each candidate kind, not just an account that
    /// already has one.
    static func `default`(for kind: AccountKind) -> AccountIcon {
        switch kind {
        case .wallet: .wallet
        case .cash: .cash
        case .savings: .savings
        case .card: .card
        case .current: .bank
        case .voucher: .voucher
        }
    }
}

extension AccountResponse {
    /// The icon this account renders with: the user's choice, or the
    /// `kind`-keyed fallback above.
    var tileIcon: AccountIcon {
        icon ?? .default(for: kind)
    }

    /// The colour this account renders with: the user's choice, or a neutral
    /// default that does not compete with a categorized transaction's own
    /// colour.
    var tileColor: PaletteColor {
        color ?? .slate
    }
}

extension CategoryResponse {
    /// The icon this category renders with: the user's choice, or the shared
    /// "uncategorized-shape" fallback also used by `TransactionDetailView`.
    var tileIcon: CategoryIcon {
        icon ?? .other
    }
}
