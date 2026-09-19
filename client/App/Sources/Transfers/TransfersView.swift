import SwiftUI
import TraccioCore

/// The Trasferimenti screen — suggested transfer pairs the user can confirm
/// or ignore, plus the client's answer to the last M2 feature with no UI
/// surface at all (`tasks/backlog.md`). Reached from Movimenti's toolbar
/// (`TransactionsView`), which shows the suggestion count.
///
/// Confirming a pair matters beyond the pair itself: until it happens, both
/// legs stay `role=personal` and count as both spending *and* income on
/// `GET /dashboard/summary` — this screen is what fixes that, not merely
/// where the count comes from.
///
/// No mockup covers this screen — see `TransferSuggestionCard` for the same
/// note.
struct TransfersView: View {
    @State private var model: TransfersViewModel

    /// Create the screen.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through — the same one
    ///     `TransactionsView` uses, not a second default instance.
    /// onUpdate:
    ///     Called once per refreshed leg after a successful confirm, so the
    ///     caller can update its own list in place.
    /// onDashboardStale:
    ///     Called after a successful confirm, so the caller can invalidate
    ///     `DataFreshness.Scope.dashboard`. Defaults to a no-op.
    init(
        client: any APIClientProtocol,
        onUpdate: @escaping (TransactionResponse) -> Void,
        onDashboardStale: @escaping () -> Void = {}
    ) {
        _model = State(
            wrappedValue: TransfersViewModel(
                client: client, onUpdate: onUpdate, onDashboardStale: onDashboardStale
            )
        )
    }

    var body: some View {
        content
            .screenChrome("Trasferimenti")
            .sensoryFeedback(.success, trigger: model.successTick)
            .sensoryFeedback(.error, trigger: model.actionFailure)
            .animation(.easeInOut(duration: 0.2), value: model.state.tag)
            .task { await model.load() }
            .refreshable { await model.load() }
    }

    /// One stable `ScrollView` across every state — see
    /// `TransactionsView.content`'s doc comment for why a per-case
    /// `ScrollView` (or, here, no `ScrollView` at all in the loading state)
    /// breaks `.refreshable`.
    private var content: some View {
        ScrollView {
            innerContent
                .padding(Spacing.gutter)
        }
    }

    @ViewBuilder
    private var innerContent: some View {
        switch model.state {
        case .idle, .loading:
            ListSkeleton()
        case .loaded(let pairs) where pairs.isEmpty:
            EmptyState(
                systemImage: "arrow.left.arrow.right", title: "Nessun trasferimento da confermare"
            )
        case .loaded(let pairs):
            list(pairs)
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare i suggerimenti",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    private func list(_ pairs: [TransferSuggestionPair]) -> some View {
        VStack(spacing: 14) {
            if model.actionFailure != nil {
                Banner(message: "Non è stato possibile completare l'azione. Riprova.")
            }
            ForEach(pairs) { pair in
                TransferSuggestionCard(
                    pair: pair,
                    accountsByID: model.accountsByID,
                    isUpdating: model.isUpdating,
                    onConfirm: { Task { await model.confirm(pair) } },
                    onReject: { Task { await model.reject(pair) } }
                )
            }
        }
    }
}
