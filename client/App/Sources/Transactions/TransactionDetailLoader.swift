import SwiftUI
import TraccioCore

/// Fetches one transaction by id, then hands off to `TransactionDetailView`.
///
/// Screens that hold only a transaction *id* — the Anticipi list, a
/// person's advances — navigate here instead of pre-fetching every row's
/// transaction up front (which was an N+1, `tasks/backlog.md`). The fetch is
/// paid once, for the row the user actually opened, behind a skeleton.
///
/// Presentation only: the one `@Observable` model below does orchestration
/// (call the client, publish the outcome), no derivation — same split as
/// every other screen (`docs/engineering.md`).
struct TransactionDetailLoader: View {
    @State private var model: Model
    private let advance: AdvanceResponse?
    private let client: any APIClientProtocol
    private let onUpdate: (TransactionResponse) -> Void
    private let onAdvanceChange: (AdvanceResponse?) -> Void
    private let onDashboardStale: () -> Void

    /// Create the loader.
    ///
    /// Parameters
    /// ----------
    /// transactionID:
    ///     The transaction to resolve and then show.
    /// advance:
    ///     The advance already in hand for this transaction, passed straight
    ///     through to `TransactionDetailView` so its advance cards render
    ///     without a second lookup. `nil` for a plain transaction.
    /// client:
    ///     The API client, shared with the pushed detail screen.
    /// onUpdate / onAdvanceChange / onDashboardStale:
    ///     Forwarded to `TransactionDetailView` unchanged — the calling list
    ///     reloads itself from these.
    init(
        transactionID: UUID,
        advance: AdvanceResponse? = nil,
        client: any APIClientProtocol = APIClient.current,
        onUpdate: @escaping (TransactionResponse) -> Void = { _ in },
        onAdvanceChange: @escaping (AdvanceResponse?) -> Void = { _ in },
        onDashboardStale: @escaping () -> Void = {}
    ) {
        _model = State(wrappedValue: Model(transactionID: transactionID, client: client))
        self.advance = advance
        self.client = client
        self.onUpdate = onUpdate
        self.onAdvanceChange = onAdvanceChange
        self.onDashboardStale = onDashboardStale
    }

    var body: some View {
        content
            .screenBackground()
            .navigationTitle("Dettaglio movimento")
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    Card(elevation: .raised) {
                        SkeletonBlock(width: 140, height: 12)
                        SkeletonBlock(width: 200, height: 34)
                        SkeletonBlock(width: 90, height: 10)
                    }
                    ListSkeleton(count: 3)
                }
                .padding(Spacing.gutter)
            }
        case .loaded(let loaded):
            TransactionDetailView(
                transaction: loaded.transaction,
                categories: [],
                advance: advance,
                account: loaded.account,
                client: client,
                onUpdate: onUpdate,
                onAdvanceChange: onAdvanceChange,
                onDashboardStale: onDashboardStale
            )
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare il movimento",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    /// Orchestration for `TransactionDetailLoader`: resolve the transaction
    /// and its account, publish the outcome. No derivation.
    @MainActor
    @Observable
    final class Model {
        /// The resolved transaction and its account, bundled so `LoadState`
        /// still only needs one type parameter.
        struct Loaded {
            var transaction: TransactionResponse
            var account: AccountResponse?
        }

        private(set) var state: LoadState<Loaded> = .idle
        private let transactionID: UUID
        private let client: any APIClientProtocol

        init(transactionID: UUID, client: any APIClientProtocol) {
            self.transactionID = transactionID
            self.client = client
        }

        func load() async {
            if case .loaded = state { return }
            state = .loading
            let client = self.client
            let id = transactionID
            do {
                async let accountsResult = client.accounts()
                let transaction = try await client.transaction(id: id)
                let account = (try? await accountsResult)?.first { $0.id == transaction.accountID }
                state = .loaded(Loaded(transaction: transaction, account: account))
            } catch {
                state = .failed
            }
        }
    }
}
