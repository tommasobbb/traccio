import SwiftUI
import TraccioCore

/// The institution picker presented from `AccountsView`'s "Collega un nuovo
/// conto" entry point — the first step of `POST /connections`: pick a bank,
/// then hand off to the system browser for SCA
/// (`.claude/rules/data-safety.md`).
///
/// A sheet rather than inline, same reasoning as `EventPickerSheet`: starting
/// a new connection is an occasional action, not something the Conti list
/// needs to make permanent room for.
struct StartConnectionSheet: View {
    let institutions: [InstitutionResponse]
    let isLoading: Bool
    let loadFailed: Bool
    let isStarting: Bool
    let startFailed: Bool
    let onSelect: (InstitutionResponse) -> Void
    let onRetryLoad: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            content
                .background(Palette.background)
                .navigationTitle("Collega un nuovo conto")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla", action: onCancel)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            EmptyState(
                systemImage: "wifi.slash",
                title: "Impossibile caricare le banche disponibili",
                description: "Verifica che il backend sia in esecuzione, poi riprova.",
                tone: .warning,
                actionTitle: "Riprova",
                action: onRetryLoad
            )
        } else if institutions.isEmpty {
            EmptyState(systemImage: "building.columns", title: "Nessuna banca disponibile")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if startFailed {
                        Banner(message: "Non è stato possibile avviare il collegamento. Riprova.")
                    }
                    institutionsCard
                }
                .padding(Spacing.gutter)
            }
        }
    }

    private var institutionsCard: some View {
        Card {
            EyebrowLabel(text: "Banche disponibili")
            VStack(spacing: 0) {
                ForEach(institutions, id: \.name) { institution in
                    institutionRow(institution)
                    if institution.name != institutions.last?.name {
                        Divider().overlay(Palette.separatorSubtle)
                    }
                }
            }
        }
    }

    private func institutionRow(_ institution: InstitutionResponse) -> some View {
        Button {
            onSelect(institution)
        } label: {
            HStack(spacing: 10) {
                BankLogoView(logo: institution.logo, name: institution.name, size: 26)
                Text(institution.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkQuaternary)
            }
            .padding(.vertical, Spacing.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
    }
}
