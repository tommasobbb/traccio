import SwiftUI
import TraccioCore

/// Shown at the top of Movimenti's list whenever there is at least one
/// transfer suggestion to review — the discoverable replacement for the old
/// toolbar count. Tapping opens `TransfersView`.
///
/// A plain `.flush` card, not an accent-tinted slab: the accent is carried by
/// the one leading tile, the chevron is chrome, and the surface is card-white
/// like every other row (`docs/design/tokens.md`'s "Accent dosage").
struct TransferSuggestionsLinkCard: View {
    let count: Int
    let client: any APIClientProtocol
    let onUpdate: (TransactionResponse) -> Void
    let onDashboardStale: () -> Void

    var body: some View {
        NavigationLink {
            TransfersView(client: client, onUpdate: onUpdate, onDashboardStale: onDashboardStale)
        } label: {
            Card(elevation: .flush, contentPadding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            Palette.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("Movimenti collegati tra i tuoi conti")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    DisclosureChevron()
                }
            }
        }
        .buttonStyle(.pressable)
    }

    private var title: String {
        count == 1 ? "1 trasferimento da confermare" : "\(count) trasferimenti da confermare"
    }
}
