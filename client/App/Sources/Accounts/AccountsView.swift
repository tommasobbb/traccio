import SwiftUI
import TraccioCore

/// The Conti screen — every bank connection grouped with its accounts, the
/// consent-expiry warning the roadmap's M3 item calls for, and the client's
/// first write actions: a manual per-connection sync and re-authorization.
///
/// Adds/imports move here from three dashed cards
/// (`docs/design/canvas/Accounts.dc.html`'s `.add-card`, since retired) into
/// two toolbar buttons — see `toolbarContent`.
struct AccountsView: View {
    @State private var model = AccountsViewModel()
    @State private var editingAccount: AccountResponse?
    @State private var isPickingInstitution = false
    @State private var isCreatingManualAccount = false
    @State private var isImportingTransactions = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DataFreshness.self) private var freshness

    var body: some View {
        NavigationStack {
            content
                .screenChrome("Conti", style: .tabRoot)
                .sensoryFeedback(.success, trigger: model.successTick)
                .sensoryFeedback(.error, trigger: model.actionFailure)
                .animation(.easeInOut(duration: 0.2), value: model.state.tag)
                .refreshable { await model.load() }
                .toolbar { toolbarContent }
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-authorization completes in the system browser, outside the
            // app; returning to the foreground is the only signal the client
            // gets that it might have finished.
            if newPhase == .active {
                Task { await model.load() }
            }
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorSheet(
                account: account,
                isSaving: model.isSavingAccount,
                failureMessage: model.accountActionFailure != nil ? accountFailureMessage : nil,
                mealVouchersEnabled: model.mealVouchersEnabled,
                onSave: { alias, color, icon, kind in
                    Task {
                        await model.renameAccount(id: account.id, alias: alias)
                        if model.accountActionFailure == nil {
                            await model.setAccountAppearance(id: account.id, color: color, icon: icon)
                        }
                        // A separate write (`POST /accounts/{id}/kind`,
                        // ADR 0029): only issued when the picker actually
                        // changed something, never for a synced account
                        // (`AccountEditorSheet` only offers the picker when
                        // `onDelete` is non-`nil`, i.e. manual).
                        if model.accountActionFailure == nil, let kind {
                            await model.setAccountKind(id: account.id, kind: kind)
                        }
                        if model.accountActionFailure == nil {
                            editingAccount = nil
                        }
                    }
                },
                // A manual account (ADR 0020) can be deleted from here; a
                // synced one is removed only by the connection flow, so the
                // affordance is simply absent for it.
                onDelete: account.source == .manual
                    ? {
                        Task {
                            if await model.deleteManualAccount(id: account.id) {
                                editingAccount = nil
                            }
                        }
                    }
                    : nil,
                onCancel: { editingAccount = nil }
            )
        }
        .sheet(isPresented: $isCreatingManualAccount) {
            CreateManualAccountSheet(
                isSaving: model.isSavingAccount,
                failureMessage: model.accountActionFailure != nil ? accountFailureMessage : nil,
                mealVouchersEnabled: model.mealVouchersEnabled,
                onCreate: { alias, kind, currency, color, icon in
                    Task {
                        if await model.createManualAccount(
                            alias: alias, kind: kind, currency: currency, color: color, icon: icon
                        ) {
                            isCreatingManualAccount = false
                        }
                    }
                },
                onCancel: { isCreatingManualAccount = false }
            )
        }
        .sheet(isPresented: $isImportingTransactions) {
            ImportTransactionsSheet(
                manualAccounts: model.accounts.filter { $0.source == .manual },
                onImported: {
                    Task {
                        await model.load()
                        freshness.markStale([.dashboard, .transactions])
                        isImportingTransactions = false
                    }
                },
                onCancel: { isImportingTransactions = false }
            )
        }
        .sheet(isPresented: $isPickingInstitution) {
            StartConnectionSheet(
                institutions: model.institutions,
                isLoading: model.isLoadingInstitutions,
                loadFailed: model.institutionsLoadFailed,
                isStarting: model.isStartingConnection,
                startFailed: model.startConnectionFailed,
                onSelect: { institution in Task { await startConnection(institution) } },
                onRetryLoad: { Task { await model.loadInstitutions(country: Self.institutionCountry) } },
                onCancel: { isPickingInstitution = false }
            )
            .task { await model.loadInstitutions(country: Self.institutionCountry) }
        }
    }

    /// The only country institutions are offered in — Italian-only is a
    /// locked M3 product decision, not a client limitation to lift later.
    private static let institutionCountry = "IT"

    // MARK: Toolbar

    /// Replaces the three dashed "Collega/Crea/Importa" cards that used to
    /// sit under the list. "Importa movimenti" is always shown — even with
    /// zero manual accounts — since `ImportTransactionsSheet` already has its
    /// own empty state explaining that case; a toolbar button that
    /// appears/disappears with data state is worse than a sheet that
    /// explains itself.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isImportingTransactions = true
            } label: {
                Label("Importa movimenti", systemImage: "square.and.arrow.down")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    isPickingInstitution = true
                } label: {
                    Label("Collega un nuovo conto", systemImage: "building.columns")
                }
                Button {
                    isCreatingManualAccount = true
                } label: {
                    Label("Crea un conto manuale", systemImage: "wallet.pass")
                }
            } label: {
                Label("Aggiungi conto", systemImage: "plus")
            }
        }
    }

    private func startConnection(_ institution: InstitutionResponse) async {
        guard let url = await model.startConnection(institution) else { return }
        isPickingInstitution = false
        openURL(url)
    }

    private var accountFailureMessage: String {
        switch model.accountActionFailure {
        case .invalidAlias:
            return "Il nome non è valido. Inseriscine uno più breve."
        case .accountNotEmpty:
            return "Il conto contiene ancora movimenti. Eliminali prima di eliminare il conto."
        case .generic, nil:
            return "Non è stato possibile salvare le modifiche. Riprova."
        }
    }

    /// One stable `ScrollView` across every state — see
    /// `TransactionsView.content`'s doc comment for why a per-case
    /// `ScrollView` breaks `.refreshable`.
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
            ListSkeleton(count: 4)
        case .loaded(let connections) where connections.isEmpty && model.accounts.isEmpty:
            EmptyState(
                systemImage: "creditcard",
                title: "Nessun conto",
                description: "Collega una banca o crea un conto manuale per il contante.",
                actionTitle: "Collega un conto",
                action: { isPickingInstitution = true }
            )
        case .loaded(let connections):
            list(connections)
        case .failed:
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare i conti",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: { Task { await model.load() } }
            )
        }
    }

    private func list(_ connections: [ConnectionResponse]) -> some View {
        let groups = TraccioCore.groupByConnection(connections: connections, accounts: model.accounts)
        let attentionNeeded = connections.filter {
            $0.consentState == .expiringSoon || $0.consentState == .expired
        }
        return LazyVStack(spacing: 14) {
            if let actionFailure = model.actionFailure {
                Banner(message: actionFailureMessage(actionFailure))
            }
            ForEach(attentionNeeded) { connection in
                Banner(
                    message: warningMessage(for: connection),
                    ctaTitle: "Rinnova ora",
                    isCTALoading: model.reauthorizing.contains(connection.id),
                    ctaAction: { Task { await reauthorize(connection.id) } }
                )
            }
            ForEach(groups, id: \.groupID) { group in
                connectionCard(group)
            }
        }
    }

    /// Copy for a failed manual sync or re-authorization
    /// (`AccountsViewModel.actionFailure`) — previously assigned but never
    /// read, so a failed action disappeared silently beyond the spinner
    /// stopping (`tasks/backlog.md`). Distinct from `warningMessage(for:)`
    /// below: that one is proactive (renew before it bites), this one is
    /// reactive (the action you just took didn't work, and why).
    private func actionFailureMessage(_ failure: AccountsViewModel.ActionFailure) -> String {
        switch failure {
        case .consentExpired:
            return "Sincronizzazione non riuscita: il consenso è scaduto. Rinnova per continuare."
        case .generic:
            return "Non è stato possibile completare l'operazione. Riprova."
        }
    }

    private func warningMessage(for connection: ConnectionResponse) -> String {
        switch connection.consentState {
        case .expired:
            return "Il consenso per \(connection.institutionName) è scaduto. Rinnova per continuare a sincronizzare."
        case .expiringSoon:
            let days = connection.daysUntilExpiry ?? 0
            let dayWord = days == 1 ? "giorno" : "giorni"
            return "Il consenso per \(connection.institutionName) scade tra \(days) \(dayWord). Rinnova per continuare a sincronizzare."
        case .pending, .active, .revoked, .error:
            return "Il consenso per \(connection.institutionName) richiede attenzione."
        }
    }

    private func reauthorize(_ connectionID: UUID) async {
        guard let url = await model.reauthorize(connectionID: connectionID) else { return }
        openURL(url)
    }

    // MARK: Connection card

    /// Dispatches on account count. A connection with exactly one account
    /// collapses header+row into a single flat card, so the account's name
    /// — often literally the bank's own name again (e.g. Revolut's own
    /// account name is "Revolut") — never repeats the header above it. A
    /// connection with several accounts keeps the header; its rows switch
    /// to `accountRow`'s alias-or-kind label for the same reason.
    private func connectionCard(_ group: ConnectionGroup) -> some View {
        Card {
            if let connection = group.connection, group.accounts.count == 1 {
                collapsedSingleAccountCard(connection, group.accounts[0])
            } else if let connection = group.connection {
                connectionHeader(connection)
                if !group.accounts.isEmpty {
                    Divider().overlay(Palette.separatorSubtle)
                    accountList(group.accounts)
                }
            } else if group.accounts.allSatisfy({ $0.source == .manual }) {
                // Manual accounts (ADR 0020) — no connection by design, not a
                // data inconsistency.
                EyebrowLabel(text: "Conti manuali")
                accountList(group.accounts)
            } else {
                // Accounts matching no known connection — a real data
                // inconsistency, surfaced rather than silently dropped.
                EyebrowLabel(text: "Altri conti")
                accountList(group.accounts)
            }
        }
    }

    /// The institution wordmark's footprint in this screen's headers and its
    /// collapsed single-account card — its own aspect ratio, not squeezed
    /// into a square (`BankLogoView.Style.wordmark`), since Enable Banking's
    /// marks are ~4.5:1 wide (`docs/openbanking.md`).
    private static let wordmarkHeight: CGFloat = 24
    private static let wordmarkMaxWidth: CGFloat = 180

    private func connectionHeader(_ connection: ConnectionResponse) -> some View {
        HStack(spacing: Spacing.itemGap) {
            VStack(alignment: .leading, spacing: 4) {
                BankLogoView(
                    logo: connection.institutionLogo, name: connection.institutionName,
                    style: .wordmark(height: Self.wordmarkHeight, maxWidth: Self.wordmarkMaxWidth)
                )
                statusRow(connection)
            }
            Spacer()
            syncButton(connection)
        }
    }

    /// A connection with exactly one account: the institution's own wordmark
    /// stands in for its name (`BankLogoView.Style.wordmark`) — the header
    /// name is never repeated underneath. When the account carries a user
    /// alias, that is genuinely new information (not a repeat of the
    /// institution's name), so it still gets its own line under the mark;
    /// with no alias, the wordmark alone identifies the account, same as
    /// `connectionHeader` above. Status and currency follow, plus the sync
    /// control beside it — outside the `Button`, since a `Button` can't nest
    /// another `Button`, so this is two siblings in an `HStack`, not one row.
    private func collapsedSingleAccountCard(
        _ connection: ConnectionResponse, _ account: AccountResponse
    ) -> some View {
        let title = account.alias ?? connection.institutionName
        return HStack(spacing: Spacing.itemGap) {
            Button {
                editingAccount = account
            } label: {
                HStack(spacing: Spacing.itemGap) {
                    VStack(alignment: .leading, spacing: 4) {
                        BankLogoView(
                            logo: connection.institutionLogo, name: connection.institutionName,
                            style: .wordmark(height: Self.wordmarkHeight, maxWidth: Self.wordmarkMaxWidth)
                        )
                        if let alias = account.alias {
                            Text(alias)
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.inkSecondary)
                                .lineLimit(1)
                        }
                        statusRow(connection)
                    }
                    Spacer(minLength: Spacing.tightGap)
                    Text(account.currency)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableRow)
            .accessibilityLabel("\(title) — modifica conto")

            syncButton(connection)
        }
    }

    private func statusRow(_ connection: ConnectionResponse) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusDotColor(for: connection.consentState))
                .frame(width: 7, height: 7)
            // Single-line, always — a status line that wraps floats the dot
            // above beside the middle of a multi-line block instead of its
            // first line (`docs/design/tokens.md`'s "Text never wraps"). A
            // very long institution/alias name truncates with an ellipsis
            // instead, never a second line.
            Text(statusLine(for: connection))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
    }

    private func syncButton(_ connection: ConnectionResponse) -> some View {
        IconButton(
            systemImage: "arrow.triangle.2.circlepath",
            accessibilityLabel: "Sincronizza \(connection.institutionName)",
            isLoading: model.syncing.contains(connection.id),
            action: { Task { await model.sync(connectionID: connection.id) } }
        )
    }

    private func statusDotColor(for state: ConsentState) -> Color {
        switch state {
        case .active: Palette.income
        case .expiringSoon: Palette.statusWarn
        case .expired, .revoked, .error: Palette.warning
        case .pending: Palette.inkQuaternary
        }
    }

    /// The status word only appears when there is something to flag —
    /// `statusRow`'s dot already carries "everything's fine" for `.active`,
    /// and the word made the line the longest exactly in the common case
    /// (`docs/design/tokens.md`'s "Text never wraps" — a `.lineLimit(1)` line
    /// truncates the very information a problem state needs to show).
    /// Abbreviated relative times (`relativeTimeShort`, "3 h fa" not "3 ore
    /// fa") and a short "auto" suffix keep the common case well inside one
    /// line at Conti's actual card width.
    private func statusLine(for connection: ConnectionResponse) -> String {
        let syncLabel: String
        if let lastSyncedAt = connection.lastSyncedAt {
            let relative = TraccioCore.relativeTimeShort(from: lastSyncedAt, to: Date())
            syncLabel = "Sincronizzato \(relative)"
        } else {
            syncLabel = "Mai sincronizzato"
        }
        guard let stateLabel = problemStateLabel(for: connection.consentState) else {
            return "\(syncLabel)\(automaticSyncSuffix(for: connection))"
        }
        return "\(stateLabel) · \(syncLabel.lowercased())\(automaticSyncSuffix(for: connection))"
    }

    /// `nil` for `.active` — the dot alone says "fine"; every other state
    /// still names itself, since that's exactly the case worth reading.
    private func problemStateLabel(for state: ConsentState) -> String? {
        switch state {
        case .active: nil
        case .expiringSoon: "In scadenza"
        case .expired: "Scaduto"
        case .revoked: "Revocato"
        case .error: "Errore"
        case .pending: "In attesa"
        }
    }

    /// The scheduler's own state, appended to `statusLine(for:)`. Every
    /// figure here is derived server-side (`GET /connections`) and rendered
    /// as-is — the client never computes when the next sync will happen
    /// (`docs/engineering.md`). Empty when the scheduler is off, so an ordinary
    /// manual-only setup reads exactly as it did before this existed.
    private func automaticSyncSuffix(for connection: ConnectionResponse) -> String {
        guard connection.backgroundSyncEnabled else { return "" }
        if let nextSyncAt = connection.nextSyncAt {
            let relative = TraccioCore.relativeTimeShort(from: nextSyncAt, to: Date())
            return " · auto \(relative)"
        }
        // nextSyncAt is nil while background_sync_enabled is true either
        // because it's already due (the next tick will sync it) or its
        // consent needs re-authorization rather than time to pass — the
        // consent-warning banner above already covers the latter, so a
        // single "in coda" reading is honest for both without guessing which.
        return " · auto in coda"
    }

    // MARK: Accounts

    private func accountList(_ accounts: [AccountResponse]) -> some View {
        VStack(spacing: 0) {
            ForEach(accounts) { account in
                if account.id != accounts.first?.id {
                    Divider().overlay(Palette.separatorSubtle)
                }
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: AccountResponse) -> some View {
        Button {
            editingAccount = account
        } label: {
            HStack(spacing: 10) {
                IconTile(
                    systemImage: account.tileIcon.systemImageName,
                    color: account.tileColor
                )
                Text(account.alias ?? account.kind.displayLabel)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(account.currency)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                DisclosureChevron()
            }
            .padding(.vertical, Spacing.rowPadding)
        }
        .buttonStyle(.pressableRow)
    }
}

extension ConnectionGroup {
    /// Fixed identity for the single orphaned-accounts group — `UUID(uuid:)`
    /// takes its 16 bytes directly and, unlike `UUID(uuidString:)`, cannot
    /// fail to parse, so no force-unwrap is needed to make an all-zero UUID.
    private static let orphanGroupID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Identity for `ForEach`: the connection's id, or a fixed sentinel for
    /// the single orphaned-accounts group (`connection == nil` can only
    /// occur once per list, per `groupByConnection`'s contract).
    fileprivate var groupID: UUID {
        connection?.id ?? Self.orphanGroupID
    }
}

#Preview {
    AccountsView()
}
