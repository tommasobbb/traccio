import SwiftUI

/// Which nav-title behaviour `screenChrome` applies.
enum ScreenChromeStyle {
    /// A tab's own root — Panoramica, Movimenti, Conti, Impostazioni. A
    /// large title that collapses to inline on scroll, matching every stock
    /// Apple app's top-level list (Impostazioni, Mail, Musica).
    case tabRoot
    /// A screen reached by a push (Eventi, Anticipi, Categorie e regole,
    /// Inizio tracciamento, a detail screen) — inline throughout, same as a
    /// stock app's own drill-down (Impostazioni ▸ Wi-Fi is never `.large`).
    /// This is `.automatic`'s own behaviour under a large-title parent, kept
    /// explicit so it doesn't depend on what the parent happens to do.
    case pushed
}

extension View {
    /// The chrome every screen shares: the neutral background gradient, the
    /// nav title at the display mode `style` calls for, and the soft
    /// scroll-edge effect that gives the chrome's Liquid Glass
    /// (`docs/decisions/0030-liquid-glass-chrome.md`) something to react to
    /// at the screen's own edges — not just the tab bar and toolbar, which
    /// already get it automatically.
    ///
    /// Introduced by the 2026-09-15 coherence pass
    /// (`docs/decisions/0031-visual-coherence-pass.md`): before this, each
    /// screen wired `.screenBackground()` and `.navigationTitle(_:)`
    /// separately, and the four tabs' display modes diverged (Panoramica
    /// alone was `.inline`, the other three left it `.automatic`). This is
    /// now the one place that decision lives.
    ///
    /// `scrollEdgeEffectStyle` has no macOS counterpart in this SDK, hence
    /// the `#if os(iOS)` split — same shape as
    /// `.tabBarMinimizeBehavior(_:)` in `TraccioApp.swift`.
    func screenChrome(_ title: String, style: ScreenChromeStyle = .pushed) -> some View {
        modifier(ScreenChromeModifier(title: title, style: style))
    }
}

private struct ScreenChromeModifier: ViewModifier {
    let title: String
    let style: ScreenChromeStyle

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .screenBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(style == .tabRoot ? .large : .inline)
                .scrollEdgeEffectStyle(.soft, for: .all)
        #else
            content
                .screenBackground()
                .navigationTitle(title)
        #endif
    }
}
