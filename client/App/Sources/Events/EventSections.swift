import SwiftUI
import TraccioCore

/// The event-specific cards on `EventDetailView`: the summary (net total,
/// member count, date range), the member list with per-row removal, the
/// close/reopen toggle, and the destructive delete action.
///
/// Every displayed value still arrives via `init`, never recomputed here
/// (`docs/engineering.md`): `total`/`memberCount` are `EventResponse` fields,
/// server-derived. This view owns only the confirmation-dialog state for the
/// one destructive action (delete) and calls back up to
/// `EventDetailViewModel` through plain closures, same shape as
/// `AdvanceSections`.
///
/// No mockup covers this screen (`docs/design/canvas/` has no Eventi
/// artboard), so it is built from existing tokens/components.
struct EventSections: View {
    let event: EventResponse
    let members: [TransactionResponse]
    /// Set while a close/reopen/assign/unassign/delete is in flight, to
    /// disable the actions here.
    var isUpdating: Bool = false
    /// Called after tapping a member row's remove control.
    let onUnassign: (UUID) -> Void
    /// Called to present the "Aggiungi movimenti" sheet.
    let onAddMembers: () -> Void
    /// Called to close this event.
    let onClose: () -> Void
    /// Called to reopen a previously closed event. No confirmation —
    /// reopening only restores visibility into an event still open to new
    /// members, nothing is lost.
    let onReopen: () -> Void
    /// Called after the destructive confirmation, to delete this event.
    let onDelete: () -> Void
    /// The per-category breakdown card (ADR 0028), built by the caller from
    /// `EventDetailViewModel.summary`. Slotted in right after the net-total
    /// summary; `nil` (empty event, or the fetch failed) simply omits it.
    var breakdownCard: AnyView?
    /// The date-range "Movimenti suggeriti" card (ADR 0028), built by the
    /// caller from `EventDetailViewModel.suggestions`. Slotted in after the
    /// members list; `nil` (no date range, nothing matched) omits it.
    var suggestionsCard: AnyView?

    @State private var isConfirmingDelete = false

    var body: some View {
        if let breakdownCard {
            breakdownCard
        }
        membersCard
        if let suggestionsCard {
            suggestionsCard
        }
        statusRow
        deleteRow
    }

    // MARK: Members

    private var membersCard: some View {
        Card {
            EyebrowLabel(text: "Movimenti")
            if members.isEmpty {
                Text("Nessun movimento assegnato a questo evento.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(members) { member in
                        memberRow(member)
                        if member.id != members.last?.id {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
            }
            Divider().overlay(Palette.separator)
            PillButton(title: "Aggiungi movimenti", isLoading: isUpdating, action: onAddMembers)
        }
    }

    private func memberRow(_ member: TransactionResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            Text(member.displayDescription ?? member.description)
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            AmountText(
                amount: member.amount, currencyCode: member.currency,
                kind: member.effectiveAmount == 0 ? .notCounted : (member.amount < 0 ? .spending : .income),
                font: Typography.caption
            )
            IconButton(
                systemImage: "minus.circle",
                accessibilityLabel: "Rimuovi dall'evento",
                isLoading: isUpdating,
                action: { onUnassign(member.id) }
            )
        }
        .padding(.vertical, 6)
    }

    // MARK: Status

    /// "Chiudi evento" / "Riapri evento" — no confirmation either way:
    /// closing an event does not stop new members being assigned to it
    /// server-side (`api/routers/events.py`'s `assign_transaction` has no
    /// status gate), so it is a reporting boundary, not a lock, and nothing
    /// is lost by toggling it.
    private var statusRow: some View {
        Button {
            if event.status == .closed {
                onReopen()
            } else {
                onClose()
            }
        } label: {
            HStack(spacing: 6) {
                if isUpdating {
                    ProgressView().controlSize(.mini)
                }
                Text(event.status == .closed ? "Riapri evento" : "Chiudi evento")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
    }

    // MARK: Delete

    /// "Elimina evento" — destructive, so it asks first
    /// (`.confirmationDialog`) rather than acting on a single tap, same
    /// posture as `AdvanceSections`'s unlink/write-off actions. The
    /// transactions themselves survive; only the grouping is removed
    /// (`docs/domain.md` §Event).
    private var deleteRow: some View {
        Button {
            isConfirmingDelete = true
        } label: {
            Text("Elimina evento")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.warning)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .confirmationDialog(
            "Eliminare l'evento?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive, action: onDelete)
            Button("Chiudi", role: .cancel) {}
        } message: {
            Text("I movimenti restano: perdono solo il raggruppamento in questo evento.")
        }
    }
}
