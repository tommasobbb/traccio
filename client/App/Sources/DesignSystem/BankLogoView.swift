import SwiftUI
import TraccioCore

/// A bank's logo in a rounded square, with a lettermark fallback.
///
/// The logo URL comes from Enable Banking's ASPSP `logo` (via
/// `InstitutionResponse.logo` / `ConnectionResponse.institutionLogo`);
/// `TraccioCore.institutionLogoURL` appends a resize transform so the fetch is
/// a couple of KB, not a multi-megapixel PNG. While the image loads, or if it
/// is missing or fails, the view shows the institution name's first letter —
/// the same mark `AccountsView` used everywhere before logos existed.
struct BankLogoView: View {
    let logo: String?
    let name: String
    var size: CGFloat = 40

    private var cornerRadius: CGFloat { size * 0.3 }

    var body: some View {
        Group {
            if let url = TraccioCore.institutionLogoURL(logo, width: Int(size)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(size * 0.14)
                    case .empty:
                        ProgressView().controlSize(.mini)
                    case .failure:
                        lettermark
                    @unknown default:
                        lettermark
                    }
                }
            } else {
                lettermark
            }
        }
        .frame(width: size, height: size)
        .background(Palette.neutralFill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(name)
    }

    private var lettermark: some View {
        Text(name.first.map(String.init)?.uppercased() ?? "?")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Palette.inkSecondary)
    }
}
