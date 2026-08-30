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
        case .voucher: "ticket"
        case .investment: "chart.line.uptrend.xyaxis"
        }
    }
}

extension CategoryIcon {
    /// The SF Symbol this icon renders as. Exhaustive over every case — an
    /// unmapped icon is a compile error, never a blank tile.
    var systemImageName: String {
        switch self {
        // Food and drink
        case .groceries: "cart"
        case .dining: "fork.knife"
        case .coffee: "cup.and.saucer"
        case .takeout: "takeoutbag.and.cup.and.straw"
        case .bakery: "birthday.cake"
        case .bar: "wineglass"
        // Transport
        case .transport: "bus"
        case .fuel: "fuelpump"
        case .publicTransport: "tram"
        case .car: "car"
        case .parking: "parkingsign"
        case .bike: "bicycle"
        case .train: "train.side.front.car"
        // Home
        case .housing: "house"
        case .rent: "key"
        case .maintenance: "wrench.and.screwdriver"
        case .utilities: "bolt"
        case .furniture: "sofa"
        case .internet: "wifi"
        case .phoneBill: "phone"
        // Health and personal care
        case .health: "cross.case"
        case .pharmacy: "pills"
        case .dentist: "mouth"
        case .fitness: "figure.run"
        case .personalCare: "scissors"
        // Family
        case .kids: "figure.and.child.holdinghands"
        case .pets: "pawprint"
        case .education: "graduationcap"
        case .books: "book"
        case .gifts: "gift"
        // Money
        case .fees: "percent"
        case .income: "arrow.down.circle"
        case .savings: "banknote"
        case .investments: "chart.line.uptrend.xyaxis"
        case .taxes: "building.columns"
        case .insurance: "shield"
        case .donations: "heart"
        // Shopping
        case .shopping: "bag"
        case .clothing: "tshirt"
        case .electronics: "tv"
        case .onlineShopping: "shippingbox"
        // Leisure
        case .entertainment: "ticket"
        case .streaming: "play.rectangle"
        case .movies: "film"
        case .music: "music.note"
        case .games: "gamecontroller"
        case .sports: "sportscourt"
        case .hobbies: "paintpalette"
        case .subscriptions: "arrow.triangle.2.circlepath"
        // Other
        case .travel: "airplane"
        case .hotel: "bed.double"
        case .work: "briefcase"
        case .other: "tag"
        }
    }

    /// The picker's sections — a presentation-layer grouping of the flat
    /// `CategoryIcon` set, so ~55 tiles are scannable instead of one wall.
    /// Lives here next to `systemImageName` rather than on the wire enum: the
    /// grouping, like the symbol names, is a client-only fact (ADR 0017).
    /// Every case appears in exactly one section — a `#expect` over the
    /// flattened list vs. `allCases` guards that.
    static let pickerSections: [(title: String, icons: [CategoryIcon])] = [
        ("Cibo e bevande", [.groceries, .dining, .coffee, .takeout, .bakery, .bar]),
        (
            "Trasporti",
            [.transport, .fuel, .publicTransport, .car, .parking, .bike, .train]
        ),
        (
            "Casa",
            [.housing, .rent, .maintenance, .utilities, .furniture, .internet, .phoneBill]
        ),
        ("Salute e cura", [.health, .pharmacy, .dentist, .fitness, .personalCare]),
        ("Famiglia", [.kids, .pets, .education, .books, .gifts]),
        (
            "Denaro",
            [.fees, .income, .savings, .investments, .taxes, .insurance, .donations]
        ),
        ("Acquisti", [.shopping, .clothing, .electronics, .onlineShopping]),
        (
            "Tempo libero",
            [.entertainment, .streaming, .movies, .music, .games, .sports, .hobbies, .subscriptions]
        ),
        ("Altro", [.travel, .hotel, .work, .other]),
    ]
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
