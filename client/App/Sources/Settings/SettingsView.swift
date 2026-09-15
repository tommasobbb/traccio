import SwiftUI
import TraccioCore

/// Impostazioni — the real settings, the ones you configure rather than
/// use: "Inizio tracciamento", "Buoni pasto", (iOS only) "Blocco con Face
/// ID", and the server connection. Reached from a toolbar button in the
/// top-right corner of Panoramica, not from the tab dock — revises ADR
/// 0009's fourth "Impostazioni" tab
/// (`docs/decisions/0033-more-tab-and-settings-corner.md`): the tab kept
/// growing two different kinds of content, things you *do* (Eventi,
/// Anticipi, Categorie e regole — now `MoreView`, the "Altro" tab) and
/// things you *configure* (this screen). Backup/export is tracked in
/// `tasks/backlog.md` as a later entry here.
///
/// Pushed from Panoramica's own `NavigationStack`, so it has no
/// `NavigationStack` of its own — same posture as `EventsView`/`AdvancesView`/
/// `CategorizationView`. Built from the same `Card` row idiom as every other
/// screen, not a stock `List`, so it does not reintroduce the plain-row look
/// ADR 0008 replaced.
struct SettingsView: View {
    @Environment(DataFreshness.self) private var freshness
    @Environment(AppLock.self) private var lock
    @State private var serverSettings = ServerSettingsViewModel()
    @State private var mealVouchers = MealVouchersViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.cardGap) {
                Card {
                    NavigationLink {
                        TrackingStartView(
                            model: TrackingStartViewModel(
                                onChanged: { freshness.markStale([.dashboard, .transactions]) }
                            )
                        )
                    } label: {
                        settingsRow(title: "Inizio tracciamento", systemImage: "calendar.badge.clock")
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Palette.separator)
                    mealVouchersRow
                    #if os(iOS)
                    Divider().overlay(Palette.separator)
                    biometricLockRow
                    #endif
                }
                serverCard
            }
            .padding(Spacing.gutter)
        }
        .screenChrome("Impostazioni")
        .task {
            mealVouchers.onChanged = { freshness.markStale([.dashboard]) }
            await mealVouchers.load()
        }
    }

    /// "Buoni pasto" toggle (ADR 0029) — off by default, since most users
    /// have no meal-voucher benefit. Disabled while a load or a flip is in
    /// flight; the toggle stays at its last known value rather than
    /// flickering if the initial load fails, and a caption explains the
    /// failure so the user knows to retry.
    private var mealVouchersRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                isOn: Binding(
                    get: { mealVouchers.isEnabled ?? false },
                    set: { newValue in Task { await mealVouchers.setEnabled(newValue) } }
                )
            ) {
                settingsRowLabel(title: "Buoni pasto", systemImage: "fork.knife")
            }
            .tint(Palette.accent)
            .disabled(mealVouchers.isEnabled == nil || mealVouchers.isSaving)
            .padding(.vertical, 4)
            if mealVouchers.loadFailed {
                Text("Impossibile aggiornare l'impostazione. Riprova.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
            } else {
                Text("Lo speso in buoni pasto è mostrato a parte ed escluso dal totale del periodo.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    /// Base URL and API token (ADR 0014) — where `APIClient.current` used to
    /// be hardcoded to local `make run`. "Verifica e salva" checks the
    /// values actually work before persisting them; see
    /// `ServerSettingsViewModel`'s doc comment for why.
    private var serverCard: some View {
        Card {
            EyebrowLabel(text: "Server")
            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                TextField("http://localhost:8000", text: $serverSettings.baseURLText)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Token API")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                SecureField(
                    "Vuoto se il server non richiede un token", text: $serverSettings.apiTokenText
                )
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            }
            if case .failure(let message) = serverSettings.state {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
            } else if serverSettings.state == .success {
                Text("Connessione verificata.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.income)
            }
            PillButton(
                title: "Verifica e salva",
                isLoading: serverSettings.state == .checking
            ) {
                Task { await serverSettings.verifyAndSave() }
            }
            Text("Riavvia l'app perché le altre schermate usino la nuova configurazione.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func settingsRow(title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            settingsRowLabel(title: title, systemImage: systemImage)
            Spacer()
            DisclosureChevron()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The icon-tile-plus-title lead-in shared by every row, whatever
    /// trailing control it ends in — a `NavigationLink`'s chevron
    /// (`settingsRow`) or, on iOS, a `Toggle` (`biometricLockRow`).
    private func settingsRowLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Palette.neutralFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
        }
    }

    #if os(iOS)
    /// Biometric lock toggle (`docs/decisions/0013-biometric-lock.md`) — iOS
    /// only, same scoping as the feature itself. Disabled with an
    /// explanatory caption when the device has no passcode set at all, the
    /// one case `.deviceOwnerAuthentication` cannot evaluate.
    @ViewBuilder
    private var biometricLockRow: some View {
        Toggle(isOn: Bindable(lock).isEnabled) {
            settingsRowLabel(title: "Blocco con Face ID", systemImage: "faceid")
        }
        .tint(Palette.accent)
        .disabled(!lock.isBiometryAvailable)
        .padding(.vertical, 4)
        if !lock.isBiometryAvailable {
            Text("Imposta un codice di sblocco sul dispositivo per usare il blocco.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
    #endif
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(DataFreshness())
            .environment(
                AppLock(
                    authenticator: UnavailableBiometricAuthenticator(),
                    defaults: UserDefaults(suiteName: "SettingsView.preview") ?? .standard
                )
            )
    }
}
