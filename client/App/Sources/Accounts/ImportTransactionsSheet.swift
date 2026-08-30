import SwiftUI
import TraccioCore
import UniformTypeIdentifiers

/// "Importa movimenti" — bring a spreadsheet or CSV of a feed Traccio cannot
/// connect to (Satispay) onto a manual account (ADR 0023).
///
/// The user picks a profile, a file, and the target account(s), sees a
/// preview (how many movements are new, already imported, or invalid), then
/// commits. Re-importing the same file is safe — the backend deduplicates on
/// each movement's stable key.
///
/// No mockup covers this; it is built from existing tokens/components
/// (`Card`, `EyebrowLabel`, `PillButton`, `Banner`, `EmptyState`).
struct ImportTransactionsSheet: View {
    /// The caller's manual accounts (ADR 0020) — the only accounts an import
    /// can target. A synced account's history is bank-owned.
    let manualAccounts: [AccountResponse]
    /// Called after a successful commit so the caller can reload and mark the
    /// dashboard/transactions stale.
    let onImported: () -> Void
    let onCancel: () -> Void

    @State private var model = ImportTransactionsViewModel()
    @State private var profile: Profile = .satispay
    @State private var primaryAccountID: UUID?
    @State private var voucherAccountID: UUID?
    @State private var pickedFile: PickedFile?
    @State private var isPickingFile = false
    @State private var fileError: String?

    /// The import profiles offered in the UI. The wire keys match the
    /// backend's `PROFILES`.
    private enum Profile: String, CaseIterable, Identifiable {
        case satispay
        case generic
        var id: String { rawValue }
        var label: String { self == .satispay ? "Satispay" : "CSV generico" }
        /// Satispay splits an amount across a balance account and a separate
        /// meal-voucher account.
        var needsVoucherAccount: Bool { self == .satispay }
    }

    /// A file the user chose, already read and base64-encoded so the view
    /// model stays free of file I/O.
    private struct PickedFile: Equatable {
        let name: String
        let base64: String
        let byteCount: Int
    }

    /// Matches `Settings.import_max_bytes` (ADR 0023) so an over-limit file is
    /// caught here rather than after a wasted round-trip.
    private static let maxBytes = 2 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if manualAccounts.isEmpty {
                    EmptyState(
                        systemImage: "wallet.pass",
                        title: "Nessun conto manuale",
                        description: "Crea prima un conto manuale su cui importare i movimenti."
                    )
                } else {
                    form
                }
            }
            .background(Palette.background)
            .navigationTitle("Importa movimenti")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla", action: onCancel)
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: Self.allowedTypes,
            onCompletion: handleFileSelection
        )
    }

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.commaSeparatedText, .spreadsheet]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }()

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let fileError {
                    Banner(message: fileError)
                }
                if case .failed(let failure) = model.phase {
                    Banner(message: Self.message(for: failure))
                }

                Card {
                    EyebrowLabel(text: "Formato")
                    Picker("Formato", selection: $profile) {
                        ForEach(Profile.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: profile) { _, _ in resetPreview() }
                }

                Card {
                    EyebrowLabel(text: "File")
                    Button {
                        isPickingFile = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text(pickedFile?.name ?? "Scegli un file")
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(Typography.body)
                        .foregroundStyle(pickedFile == nil ? Palette.accent : Palette.ink)
                    }
                    .buttonStyle(.plain)
                }

                accountCard(
                    title: profile.needsVoucherAccount ? "Conto principale" : "Conto",
                    selection: $primaryAccountID,
                    exclude: voucherAccountID
                )
                if profile.needsVoucherAccount {
                    accountCard(
                        title: "Conto Buoni Pasto",
                        selection: $voucherAccountID,
                        exclude: primaryAccountID
                    )
                }

                if case .previewed(let response) = model.phase {
                    previewCard(response)
                }
                if case .committed(let response) = model.phase {
                    committedCard(response)
                }

                actions
            }
            .padding(20)
        }
    }

    private func accountCard(
        title: String, selection: Binding<UUID?>, exclude: UUID?
    ) -> some View {
        Card {
            EyebrowLabel(text: title)
            Picker(title, selection: selection) {
                Text("Scegli…").tag(UUID?.none)
                ForEach(manualAccounts.filter { $0.id != exclude }) { account in
                    Text(account.displayName ?? "Conto").tag(UUID?.some(account.id))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selection.wrappedValue) { _, _ in resetPreview() }
        }
    }

    private func previewCard(_ response: ImportPreviewResponse) -> some View {
        Card {
            EyebrowLabel(text: "Anteprima")
            HStack(spacing: 16) {
                stat("Nuovi", response.summary.new, Palette.accent)
                stat("Già importati", response.summary.alreadyImported, Palette.inkSecondary)
                stat("In errore", response.summary.invalid, Palette.inkSecondary)
            }
            ForEach(response.rows.prefix(40)) { row in
                previewRow(row)
                Divider().overlay(Palette.separator)
            }
            if response.rows.count > 40 {
                Text("… e altri \(response.rows.count - 40)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private func previewRow(_ row: ImportRowResponse) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.description ?? Self.reasonLabel(row.reason))
                    .font(Typography.body)
                    .foregroundStyle(row.status == .invalid ? Palette.inkSecondary : Palette.ink)
                    .lineLimit(1)
                Text(Self.statusLabel(row.status))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            if let amount = row.amount, let currency = row.currency {
                AmountText(
                    amount: amount, currencyCode: currency,
                    kind: amount < 0 ? .spending : .income, font: Typography.compactFigure
                )
            }
        }
        .padding(.vertical, 6)
    }

    private func committedCard(_ response: ImportCommitResponse) -> some View {
        Card {
            EyebrowLabel(text: "Importati")
            Text("\(response.imported) movimenti importati, \(response.skipped) già presenti.")
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
        }
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(Typography.statFigure).foregroundStyle(color)
            Text(label).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .previewed(let response):
            PillButton(
                title: "Importa \(response.summary.new) movimenti",
                isLoading: false,
                action: { Task { await runCommit() } }
            )
            .disabled(response.summary.new == 0)
        case .committed:
            PillButton(title: "Fatto", isLoading: false, action: onImported)
        case .working:
            PillButton(title: "…", isLoading: true, action: {})
        case .idle, .failed:
            PillButton(title: "Anteprima", isLoading: false, action: { Task { await runPreview() } })
                .disabled(!canPreview)
        }
    }

    private var canPreview: Bool {
        guard pickedFile != nil, primaryAccountID != nil else { return false }
        if profile.needsVoucherAccount { return voucherAccountID != nil }
        return true
    }

    private func request() -> ImportPreviewRequest? {
        guard let file = pickedFile, let primary = primaryAccountID else { return nil }
        return ImportPreviewRequest(
            accountID: primary,
            voucherAccountID: profile.needsVoucherAccount ? voucherAccountID : nil,
            profile: profile.rawValue,
            filename: file.name,
            contentBase64: file.base64
        )
    }

    private func runPreview() async {
        guard let request = request() else { return }
        await model.preview(request)
    }

    private func runCommit() async {
        guard let request = request() else { return }
        await model.commit(request)
    }

    private func resetPreview() {
        fileError = nil
        model.reset()
    }

    private func handleFileSelection(_ result: Result<URL, any Error>) {
        resetPreview()
        switch result {
        case .failure:
            fileError = "Non è stato possibile aprire il file."
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= Self.maxBytes else {
                    fileError = "Il file è troppo grande."
                    return
                }
                pickedFile = PickedFile(
                    name: url.lastPathComponent,
                    base64: data.base64EncodedString(),
                    byteCount: data.count
                )
            } catch {
                fileError = "Non è stato possibile leggere il file."
            }
        }
    }

    private static func message(for failure: ImportTransactionsViewModel.Failure) -> String {
        switch failure {
        case .tooLarge: "Il file è troppo grande."
        case .badFile: "Il file non corrisponde al formato scelto."
        case .generic: "Non è stato possibile importare il file. Riprova."
        }
    }

    private static func statusLabel(_ status: ImportRowResponse.Status) -> String {
        switch status {
        case .new: "Nuovo"
        case .alreadyImported: "Già importato"
        case .invalid: "In errore"
        }
    }

    private static func reasonLabel(_ reason: String?) -> String {
        switch reason {
        case "amount_split_mismatch": "Gli importi non tornano"
        case "unknown_status": "Stato non riconosciuto"
        case "invalid_amount": "Importo non valido"
        case "invalid_date": "Data non valida"
        case "missing_id": "Riga senza identificativo"
        case "zero_amount": "Importo a zero"
        default: "Riga non importabile"
        }
    }
}
