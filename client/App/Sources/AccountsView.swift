import SwiftUI
import TraccioCore

/// The single screen of the M0 app: the caller's accounts in a plain list.
///
/// Deliberately minimal and native — a `List` in a `NavigationStack` with
/// pull-to-refresh. It renders exactly what the backend returns; any number or
/// total would be a backend concern, not a view feature (see `client/CLAUDE.md`).
struct AccountsView: View {
    @State private var model = AccountsViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Accounts")
                .refreshable { await model.load() }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let accounts) where accounts.isEmpty:
            ContentUnavailableView("No accounts", systemImage: "creditcard")
        case .loaded(let accounts):
            List(accounts) { account in
                AccountRow(account: account)
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load accounts", systemImage: "wifi.slash")
            } description: {
                Text("Check that the backend is running, then pull to refresh.")
            }
        }
    }
}

/// One row: the account's display name (or a fallback), its kind, and currency.
private struct AccountRow: View {
    let account: AccountResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.name ?? "Unnamed account")
                .font(.headline)
            HStack(spacing: 6) {
                Text(account.kind.rawValue.capitalized)
                Text("·")
                Text(account.currency)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
