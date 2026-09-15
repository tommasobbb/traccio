import SwiftUI
import TraccioCore

/// "Collega come doppia uscita" — presented after picking two outflows in
/// Movimenti's pick-two selection mode (`TraccioCore.canLinkAsFundedPayment`).
///
/// Unlike a two-sided transfer, sign alone doesn't say which leg funds which
/// (ADR 0022): both legs are negative, so the user picks explicitly instead
/// of the app guessing. Preselects the non-wallet leg when exactly one of
/// the two accounts is a `wallet` — the same signal `detect_transfers` uses
/// to orient an automatic suggestion — but always leaves the choice visible
/// and changeable.
///
/// No mockup covers this (`docs/design/canvas/Transactions.dc.html` predates
/// ADR 0022), so it is built from existing tokens/components (`Card`,
/// `EyebrowLabel`, `Banner`, `AmountText`, `PillButton`) — the same posture
/// `TransferSuggestionCard` and `CreateAdvanceSheet` already took.
struct FundedPaymentOrientationSheet: View {
    let a: TransactionResponse
    let b: TransactionResponse
    /// Account id → account, for each leg's name and the wallet-heuristic
    /// preselection. Best-effort: a missing lookup falls back to a generic
    /// label and disables the heuristic rather than failing the sheet.
    let accountsByID: [UUID: AccountResponse]
    var isLinking: Bool
    /// A generic failure message from the last attempt, or `nil`.
    var failureMessage: String?
    /// Called with the id of the leg the user chose as the funding one.
    let onConfirm: (_ fundingID: UUID) -> Void
    let onCancel: () -> Void

    @State private var fundingID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failureMessage {
                        Banner(message: failureMessage)
                    }
                    Text(
                        "Una delle due uscite ha finanziato l'altra. Quella verrà contata zero; l'altra resta la spesa reale."
                    )
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    legOption(a)
                    legOption(b)
                }
                .padding(20)
            }
            .screenBackground()
            .navigationTitle("Doppia uscita")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Collega") {
                        if let fundingID { onConfirm(fundingID) }
                    }
                    .disabled(isLinking || fundingID == nil)
                }
            }
        }
        .onAppear {
            if fundingID == nil {
                fundingID = Self.preselectedFundingID(a: a, b: b, accountsByID: accountsByID)
            }
        }
    }

    private func legOption(_ leg: TransactionResponse) -> some View {
        let isChosen = fundingID == leg.id
        return Button {
            fundingID = leg.id
        } label: {
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        EyebrowLabel(text: isChosen ? "Finanzia l'altra" : "Conto")
                        Text(accountsByID[leg.accountID]?.name ?? "Conto")
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        AmountText(
                            amount: leg.amount, currencyCode: leg.currency,
                            kind: .spending, font: Typography.compactFigure
                        )
                    }
                    Spacer()
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isChosen ? Palette.accent : Palette.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Defaults the funding pick to the non-wallet leg when exactly one of
    /// the two accounts is a `wallet` — the same signal `detect_transfers`
    /// uses to orient an automatic `funded_payment` suggestion (ADR 0022).
    /// `nil` (no default) when the heuristic can't tell, leaving the user to
    /// choose from scratch.
    private static func preselectedFundingID(
        a: TransactionResponse, b: TransactionResponse, accountsByID: [UUID: AccountResponse]
    ) -> UUID? {
        let aIsWallet = accountsByID[a.accountID]?.kind == .wallet
        let bIsWallet = accountsByID[b.accountID]?.kind == .wallet
        guard aIsWallet != bIsWallet else { return nil }
        return aIsWallet ? b.id : a.id
    }
}
