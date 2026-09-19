#if os(iOS)
import SwiftUI

/// What the app shows the instant it stops being `.active` — including the
/// app-switcher snapshot iOS takes right then
/// (`docs/engineering.md`: "consider what appears in the app
/// switcher snapshot when the app is backgrounded").
///
/// Deliberately dumber than `LockScreenView` and shown far more often: no
/// state, no amounts, no account names, not even whether biometric lock is
/// enabled — just the wordmark on the background color. This view is what
/// must be safe to leak into a system-owned snapshot, so it carries nothing
/// worth leaking.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: Spacing.itemGap) {
                ZStack {
                    Circle().fill(Palette.neutralFill)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Palette.accent)
                }
                .frame(width: 60, height: 60)
                Text("Traccio")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    PrivacyCoverView()
}
#endif
