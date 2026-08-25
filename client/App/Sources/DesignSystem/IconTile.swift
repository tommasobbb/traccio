import SwiftUI
import TraccioCore

/// A rounded, tinted tile with a centered SF Symbol — the shared visual for
/// "this row's semantic colour and icon" (an account, later a category).
///
/// Introduced for account appearance (ADR 0017); reused by categories once
/// `CategoryIcon` lands. `AccountIcon`'s mapping to a concrete SF Symbol name
/// lives here rather than on the enum itself — the backend has no notion that
/// SF Symbols exist (see `AccountIcon`'s own doc comment), so the mapping is a
/// client-only, presentation-layer fact.
struct IconTile: View {
    let systemImage: String
    let color: PaletteColor
    var diameter: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * 0.42, weight: .medium))
            .foregroundStyle(Palette.color(color))
            .frame(width: diameter, height: diameter)
            .background(Palette.tint(color))
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension AccountIcon {
    /// The SF Symbol this icon renders as. Exhaustive over every case — an
    /// unmapped icon is a compile error, never a blank tile.
    var systemImageName: String {
        switch self {
        case .bank: "building.columns"
        case .card: "creditcard"
        case .wallet: "wallet.pass"
        case .savings: "banknote"
        case .cash: "dollarsign.circle"
        case .phone: "iphone"
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        IconTile(systemImage: AccountIcon.bank.systemImageName, color: .indigo)
        IconTile(systemImage: AccountIcon.card.systemImageName, color: .purple)
        IconTile(systemImage: AccountIcon.wallet.systemImageName, color: .teal)
        IconTile(systemImage: AccountIcon.savings.systemImageName, color: .green)
    }
    .padding()
}
