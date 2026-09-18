import SwiftUI
import TraccioCore

/// The first-run screen: shown instead of the four-tab shell until
/// `ServerConfigurationStore.isConfigured` is true, so a fresh install
/// doesn't dump the user into four tabs that all fail before they've had a
/// chance to enter the server they're supposed to already know about.
///
/// Reuses `ServerSettingsViewModel` as-is — same verify-before-persist
/// behavior as Impostazioni ▸ Server (ADR 0014) — rather than a parallel
/// onboarding-specific flow. `onComplete` fires once `verifyAndSave()`
/// actually succeeds, which is also how this sidesteps ADR 0014's
/// documented "restart to apply" limitation for the first-run case
/// specifically: the four-tab `TabView` in `TraccioApp` is not constructed
/// at all until after a successful save, so every view model's
/// `= APIClient.current` default parameter reads the just-saved
/// configuration on its very first construction. A config *change* after
/// onboarding still needs a relaunch, unchanged — that limitation was
/// judged out of scope for this slice too, same as ADR 0014's.
struct OnboardingView: View {
    @State private var serverSettings = ServerSettingsViewModel()
    let onComplete: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                Card {
                    EyebrowLabel(text: "Server")
                    fieldsSection
                    if case .failure(let message) = serverSettings.state {
                        Text(message)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.warning)
                    }
                    PillButton(
                        title: "Verifica e continua",
                        isLoading: serverSettings.state == .checking
                    ) {
                        Task { await serverSettings.verifyAndSave() }
                    }
                }
            }
            .padding(Spacing.gutter)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .onChange(of: serverSettings.state) { _, newState in
            if newState == .success {
                onComplete()
            }
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.itemGap) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Palette.accent)
                .clipShape(Circle())
                .padding(.top, 32)

            Text("Benvenuto in Traccio")
                .font(Typography.heroFigure)
                .foregroundStyle(Palette.ink)

            Text("Per iniziare, inserisci l'indirizzo del tuo backend e, se richiesto, il token API — li trovi dove hai fatto il deploy.")
                .font(Typography.body)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var fieldsSection: some View {
        Group {
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
        }
    }
}
