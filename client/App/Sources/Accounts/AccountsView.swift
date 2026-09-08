import SwiftUI
import TraccioCore

/// The Conti screen — every bank connection grouped with its accounts, the
/// consent-expiry warning the roadmap's M3 item calls for, and the client's
/// first write actions: a manual per-connection sync and re-authorization.
///
/// Follows `docs/design/canvas/Accounts.dc.html`.
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
                .background(Palette.background)
                .navigationTitle("Conti")
                .sensoryFeedback(.success, trigger: model.successTick)
                .sensoryFeedback(.error, trigger: model.actionFailure)
                .animation(.easeInOut(duration: 0.2), value: stateTag)
                .refreshable { await model.load() }
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
                onSave: { alias, color, icon in
                    Task {
                        await model.renameAccount(id: account.id, alias: alias)
                        if model.accountActionFailure == nil {
                            await model.setAccountAppearance(id: account.id, color: color, icon: icon)
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

    /// A cheap discriminator for `.animation(_:value:)` — see
    /// `TransactionsView.stateTag`'s doc comment for why not `Equatable`.
    private var stateTag: String {
        switch model.state {
        case .idle, .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ScrollView {
                ListSkeleton(count: 4)
                    .padding(Spacing.gutter)
            }
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
        return ScrollView {
            LazyVStack(spacing: 14) {
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
                addConnectionCard
                addManualAccountCard
                if model.accounts.contains(where: { $0.source == .manual }) {
                    importTransactionsCard
                }
            }
            .padding(20)
        }
    }

    /// The dashed "Collega un nuovo conto" entry point, per
    /// `docs/design/canvas/Accounts.dc.html`'s `.add-card`.
    private var addConnectionCard: some View {
        Button {
            isPickingInstitution = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Collega un nuovo conto")
                    .font(Typography.caption.weight(.bold))
            }
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.pressable)
    }

    /// The dashed "Crea un conto manuale" entry point (ADR 0020) — a cash
    /// float or an investment pass-through, tracked by hand with no bank
    /// behind it. Sits directly below "Collega un nuovo conto"; same shape,
    /// different glyph.
    private var addManualAccountCard: some View {
        Button {
            isCreatingManualAccount = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wallet.pass")
                    .font(.system(size: 13, weight: .bold))
                Text("Crea un conto manuale")
                    .font(Typography.caption.weight(.bold))
            }
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.pressable)
    }

    /// "Importa movimenti da file" (ADR 0023) — bring a Satispay export or a
    /// CSV onto a manual account. Shown only when a manual account exists to
    /// receive the movements; same dashed shape as the two cards above.
    private var importTransactionsCard: some View {
        Button {
            isImportingTransactions = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .bold))
                Text("Importa movimenti da file")
                    .font(Typography.caption.weight(.bold))
            }
            .foregroundStyle(Palette.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .buttonStyle(.pressable)
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

    private func connectionCard(_ group: ConnectionGroup) -> some View {
        Card {
            if let connection = group.connection {
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

    private func connectionHeader(_ connection: ConnectionResponse) -> some View {
        HStack(spacing: 12) {
            BankLogoView(
                logo: connection.institutionLogo, name: connection.institutionName, size: 40
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.institutionName)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor(for: connection.consentState))
                        .frame(width: 7, height: 7)
                    Text(statusLine(for: connection))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer()
            IconButton(
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityLabel: "Sincronizza \(connection.institutionName)",
                isLoading: model.syncing.contains(connection.id),
                action: { Task { await model.sync(connectionID: connection.id) } }
            )
        }
    }

    private func statusDotColor(for state: ConsentState) -> Color {
        switch state {
        case .active: Palette.income
        case .expiringSoon: Palette.statusWarn
        case .expired, .revoked, .error: Palette.warning
        case .pending: Palette.inkQuaternary
        }
    }

    private func statusLine(for connection: ConnectionResponse) -> String {
        let stateLabel: String
        switch connection.consentState {
        case .active: stateLabel = "Attivo"
        case .expiringSoon: stateLabel = "In scadenza"
        case .expired: stateLabel = "Scaduto"
        case .revoked: stateLabel = "Revocato"
        case .error: stateLabel = "Errore"
        case .pending: stateLabel = "In attesa"
        }
        let syncLabel: String
        if let lastSyncedAt = connection.lastSyncedAt {
            syncLabel = "sincronizzato \(TraccioCore.relativeTime(from: lastSyncedAt, to: Date()))"
        } else {
            syncLabel = "mai sincronizzato"
        }
        return "\(stateLabel) · \(syncLabel)\(automaticSyncSuffix(for: connection))"
    }

    /// The scheduler's own state, appended to `statusLine(for:)`. Every
    /// figure here is derived server-side (`GET /connections`) and rendered
    /// as-is — the client never computes when the next sync will happen
    /// (`client/CLAUDE.md`). Empty when the scheduler is off, so an ordinary
    /// manual-only setup reads exactly as it did before this existed.
    private func automaticSyncSuffix(for connection: ConnectionResponse) -> String {
        guard connection.backgroundSyncEnabled else { return "" }
        if let nextSyncAt = connection.nextSyncAt {
            let relative = TraccioCore.relativeTime(from: nextSyncAt, to: Date())
            return " · automatica, prossima \(relative)"
        }
        // nextSyncAt is nil while background_sync_enabled is true either
        // because it's already due (the next tick will sync it) or its
        // consent needs re-authorization rather than time to pass — the
        // consent-warning banner above already covers the latter, so a
        // single "in coda" reading is honest for both without guessing which.
        return " · automatica, in coda"
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
                Text(account.displayName ?? "Conto")
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(account.currency)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .padding(.vertical, Spacing.rowPadding)
        }
        .buttonStyle(.pressableRow)
    }
}

extension ConnectionGroup {
    /// Identity for `ForEach`: the connection's id, or a fixed sentinel for
    /// the single orphaned-accounts group (`connection == nil` can only
    /// occur once per list, per `groupByConnection`'s contract).
    fileprivate var groupID: UUID {
        connection?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}

#Preview {
    AccountsView()
}
