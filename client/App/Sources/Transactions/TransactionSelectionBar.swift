import SwiftUI
import TraccioCore

/// The bottom bar shown while Movimenti is in transfer-pairing selection
/// mode: guidance until two rows are picked, then either the link action or
/// the reason it is blocked, plus any failure from the last attempt.
struct TransactionSelectionBar: View {
    let selectedTransactions: [TransactionResponse]
    let canLinkAsTwoSided: Bool
    let canLinkAsFundedPaymentSelection: Bool
    let isLinking: Bool
    let linkFailure: TransactionsViewModel.LinkFailure?
    let onLinkAsTransfer: () -> Void
    let onChooseFundedPaymentOrientation: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let linkFailureMessage {
                Banner(message: linkFailureMessage)
            }
            if canLinkAsTwoSided {
                PillButton(
                    title: "Collega come trasferimento", isLoading: isLinking, action: onLinkAsTransfer
                )
            } else if canLinkAsFundedPaymentSelection {
                PillButton(
                    title: "Collega come doppia uscita", isLoading: isLinking,
                    action: onChooseFundedPaymentOrientation
                )
            } else {
                Text(selectionGuidance)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: Rectangle())
        .overlay(alignment: .top) { Divider() }
    }

    /// What to tell the user given how many rows are selected and whether
    /// they can be linked. Pure view copy derived from the two
    /// `TransactionResponse`s — the backend stays the authority on the link.
    private var selectionGuidance: String {
        switch selectedTransactions.count {
        case 0, 1:
            return "Seleziona due movimenti da collegare come trasferimento"
        default:
            let a = selectedTransactions[0]
            let b = selectedTransactions[1]
            if a.role != .personal || b.role != .personal {
                return "Uno dei due movimenti è già collegato (trasferimento, anticipo o rimborso)"
            }
            if a.currency != b.currency { return "I due movimenti hanno valute diverse" }
            if a.accountID == b.accountID { return "I due movimenti sono sullo stesso conto" }
            return "Questi due movimenti non possono formare un trasferimento"
        }
    }

    private var linkFailureMessage: String? {
        switch linkFailure {
        case nil: nil
        case .alreadyLinked: "Uno dei due movimenti è già in un trasferimento."
        case .notLinkable: "Questi due movimenti non possono formare un trasferimento."
        case .generic: "Non è stato possibile collegare i movimenti. Riprova."
        }
    }
}
