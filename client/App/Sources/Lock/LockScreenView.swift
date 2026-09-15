#if os(iOS)
import SwiftUI

/// The full-screen biometric lock gate, shown by `LockOverlayModifier`
/// whenever `AppLock.state != .unlocked`. No canvas artboard covers this
/// screen — same posture as `SettingsView` (ADR 0009): simple enough to
/// compose from existing tokens, built only from components already in
/// `DesignSystem/` (`Card` is not one of them — this is full-bleed, not a
/// card-shaped grouping).
struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                icon
                VStack(spacing: 6) {
                    Text("Traccio è bloccato")
                        .font(Typography.statFigure)
                        .foregroundStyle(Palette.ink)
                    Text("Sblocca con \(lock.biometryName) per continuare")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                tail
            }
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        ZStack {
            Circle().fill(Palette.neutralFill)
            Image(systemName: iconName)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Palette.accent)
                // A quiet pulse while waiting on Face ID/Touch ID — the same
                // ambient cue the system's own biometric prompt gives
                // (`docs/decisions/0031-visual-coherence-pass.md`). Backs off
                // under Reduce Motion automatically, like every other
                // `symbolEffect` in `docs/design/tokens.md`.
                .symbolEffect(.pulse, isActive: lock.state == .authenticating)
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    private var iconName: String {
        switch lock.biometryKind {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .none: "lock.fill"
        }
    }

    @ViewBuilder
    private var tail: some View {
        switch lock.state {
        case .unlocked:
            // Never actually shown — LockOverlayModifier only presents this
            // view while state != .unlocked — but exhaustive over LockState
            // rather than a default branch, so a new case fails to compile
            // here instead of silently rendering nothing.
            EmptyView()
        case .locked:
            PillButton(title: "Sblocca con \(lock.biometryName)") {
                Task { await lock.authenticate() }
            }
        case .authenticating:
            PillButton(title: "Sblocca…", isLoading: true) {}
        case .failed(.unavailable):
            Banner(
                message: "Nessun codice di sblocco impostato su questo dispositivo.",
                ctaTitle: "Continua senza blocco",
                ctaAction: { lock.continueWithoutLock() }
            )
        case .failed:
            Banner(
                message: "Autenticazione non riuscita.",
                ctaTitle: "Riprova",
                ctaAction: { Task { await lock.authenticate() } }
            )
        }
    }
}

#Preview {
    // A dedicated suite with the preference pre-set, so the preview renders
    // the .locked tail (the state a real cold launch starts in) rather than
    // .unlocked — never .standard, so a preview run never writes the real key.
    let defaults = UserDefaults(suiteName: "LockScreenView.preview") ?? .standard
    defaults.set(true, forKey: "lock.biometricEnabled")
    return LockScreenView(lock: AppLock(authenticator: LocalAuthenticationAuthenticator(), defaults: defaults))
}
#endif
