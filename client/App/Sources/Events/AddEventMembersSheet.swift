import SwiftUI
import TraccioCore

/// "Aggiungi movimenti" — the sheet presented from `EventSections` to assign
/// transactions to an event.
///
/// Unlike `AddReimbursementSheet`'s single-selection form, tapping a
/// candidate row assigns it immediately (one `POST
/// /events/{id}/transactions` per tap) and the row disappears from the list
/// on the next redraw — `candidates` is `EventDetailViewModel
/// .availableCandidates`, which excludes whatever just became a member. The
/// sheet stays open so several transactions can be added in one visit;
/// "Fatto" dismisses it explicitly, there being no natural "submit" moment.
struct AddEventMembersSheet: View {
    /// Transactions eligible to assign (already filtered to exclude current
    /// members and, once known, narrowed to the event's currency).
    let candidates: [TransactionResponse]
    var isUpdating: Bool
    /// A message describing why the last attempt failed, or `nil`.
    var failureMessage: String?
    /// Called with the tapped candidate's id.
    let onAssign: (UUID) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    candidatesCard
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Aggiungi movimenti")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto", action: onDone)
                }
            }
        }
    }

    private var candidatesCard: some View {
        Card {
            EyebrowLabel(text: "Movimenti disponibili")
            if candidates.isEmpty {
                Text("Nessun movimento disponibile da aggiungere.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        Button { onAssign(candidate.id) } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdating)
                        if candidate.id != candidates.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: TransactionResponse) -> some View {
        HStack(spacing: 12) {
            Text(candidate.displayDescription ?? candidate.description)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            AmountText(
                amount: candidate.amount, currencyCode: candidate.currency,
                kind: candidate.amount < 0 ? .spending : .income,
                font: Typography.caption
            )
            Image(systemName: "plus.circle")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
