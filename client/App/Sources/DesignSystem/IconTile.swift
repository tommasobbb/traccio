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

extension CategoryIcon {
    /// The SF Symbol this icon renders as. Exhaustive over every case — an
    /// unmapped icon is a compile error, never a blank tile.
    var systemImageName: String {
        switch self {
        case .groceries: "cart"
        case .dining: "fork.knife"
        case .coffee: "cup.and.saucer"
        case .takeout: "takeoutbag.and.cup.and.straw"
        case .transport: "bus"
        case .fuel: "fuelpump"
        case .publicTransport: "tram"
        case .housing: "house"
        case .rent: "key"
        case .maintenance: "wrench.and.screwdriver"
        case .utilities: "bolt"
        case .health: "cross.case"
        case .shopping: "bag"
        case .clothing: "tshirt"
        case .electronics: "tv"
        case .entertainment: "ticket"
        case .streaming: "play.rectangle"
        case .movies: "film"
        case .travel: "airplane"
        case .subscriptions: "arrow.triangle.2.circlepath"
        case .fees: "percent"
        case .income: "arrow.down.circle"
        case .other: "tag"
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
