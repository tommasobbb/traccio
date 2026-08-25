import TraccioCore

/// Fallback appearance for a row that has no explicit icon/colour chosen yet
/// (ADR 0017/0018 make both optional on an account, icon-only on a category —
/// a category always carries a colour, seeded on creation).
///
/// Lifted out of `AccountsView` (previously a private `defaultIcon(for:)`) so
/// `TransactionRow` can render the same fallback rather than leaving its
/// leading tile blank whenever appearance was never set.
extension AccountResponse {
    /// The icon this account renders with: the user's choice, or a fallback
    /// that mirrors `AccountKind`'s old hardcoded glyph (wallet vs. everything
    /// else) rather than defaulting every kind to the same icon.
    var tileIcon: AccountIcon {
        icon ?? (kind == .wallet ? .wallet : .bank)
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
