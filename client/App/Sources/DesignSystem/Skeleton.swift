import SwiftUI

/// A placeholder block for a not-yet-loaded piece of content — a filled,
/// rounded rectangle in `Palette.neutralFill` with a slow shimmer. Screens
/// assemble these into a rough silhouette of what is about to arrive, so the
/// first paint is the shape of the screen rather than a lone spinner on an
/// empty field (ADR 0008's 2026-09-08 "dose, non tinta" revision).
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.neutralFill)
            .frame(width: width, height: height)
            .shimmering()
    }
}

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    /// Respect the system setting — a moving highlight is exactly what this
    /// flag is for.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay(highlight.mask(content))
                .onAppear { phase = 2 }
        }
    }

    private var highlight: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            LinearGradient(
                colors: [.clear, Palette.card.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 0.6)
            .offset(x: phase * w)
            .animation(
                .linear(duration: 1.4).repeatForever(autoreverses: false),
                value: phase
            )
        }
    }
}

extension View {
    /// Sweep a soft highlight across this view forever (skeleton placeholders).
    /// A no-op under Reduce Motion.
    func shimmering() -> some View {
        modifier(Shimmer())
    }
}

/// The Panoramica placeholder: the period strip, the raised hero, and two
/// breakdown cards — the real `DashboardView` layout with its text swapped
/// for blocks.
struct DashboardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            SkeletonBlock(height: 64, cornerRadius: Radius.row)

            Card(elevation: .raised) {
                SkeletonBlock(width: 120, height: 10)
                SkeletonBlock(width: 200, height: 40)
                SkeletonBlock(width: 40, height: 10)
                SkeletonBlock(height: 10, cornerRadius: 5)
                Divider().overlay(Palette.separator)
                HStack(spacing: 16) {
                    SkeletonBlock(width: 90, height: 32)
                    SkeletonBlock(width: 90, height: 32)
                }
            }

            ForEach(0..<2, id: \.self) { _ in
                Card {
                    SkeletonBlock(width: 100, height: 10)
                    SkeletonBlock(height: 96, cornerRadius: Radius.tile)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A generic list placeholder: `count` rows of an icon tile plus two text
/// lines, grouped in one resting card with hairlines — the shape Movimenti
/// and Conti both load into.
struct ListSkeleton: View {
    var count: Int = 6

    var body: some View {
        Card(contentPadding: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: Spacing.itemGap) {
                    SkeletonBlock(width: 28, height: 28, cornerRadius: Radius.tile)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 180, height: 11)
                        SkeletonBlock(width: 110, height: 9)
                    }
                    Spacer(minLength: 8)
                    SkeletonBlock(width: 64, height: 12)
                }
                .padding(.horizontal, Spacing.cardPadding)
                .padding(.vertical, 12)
                if index < count - 1 {
                    Divider().overlay(Palette.separatorSubtle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
