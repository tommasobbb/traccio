import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `ImportTransactionsViewModel` — the preview/commit orchestration
/// behind `ImportTransactionsSheet` (ADR 0023). The seam is `APIClientProtocol`
/// (`FakeAPIClient`); fixtures are synthetic (`.claude/rules/data-safety.md`).
@MainActor
struct ImportTransactionsViewModelTests {
    private static func request() -> ImportPreviewRequest {
        ImportPreviewRequest(
            accountID: UUID(),
            voucherAccountID: UUID(),
            profile: "satispay",
            filename: "june.xlsx",
            contentBase64: "UEsDBAo="
        )
    }

    private static func preview(new: Int, alreadyImported: Int, invalid: Int) -> ImportPreviewResponse {
        ImportPreviewResponse(
            rows: [],
            summary: ImportPreviewSummaryResponse(
                new: new, alreadyImported: alreadyImported, invalid: invalid,
                total: new + alreadyImported + invalid
            )
        )
    }

    @Test func previewPublishesTheClassifiedRowsAndForwardsTheRequest() async {
        let client = FakeAPIClient()
        await client.setImportPreviewResult(Self.preview(new: 3, alreadyImported: 1, invalid: 1))
        let model = ImportTransactionsViewModel(client: client)
        let request = Self.request()

        await model.preview(request)

        guard case .previewed(let response) = model.phase else {
            Issue.record("expected .previewed")
            return
        }
        #expect(response.summary.new == 3)
        #expect(await client.importPreviewRequests.map(\.profile) == ["satispay"])
        #expect(await client.importPreviewRequests.first?.filename == request.filename)
    }

    @Test func commitPublishesTheInsertCounts() async {
        let client = FakeAPIClient()
        await client.setImportCommitResult(ImportCommitResponse(imported: 3, skipped: 2, invalid: 1))
        let model = ImportTransactionsViewModel(client: client)

        await model.commit(Self.request())

        #expect(model.phase == .committed(ImportCommitResponse(imported: 3, skipped: 2, invalid: 1)))
        #expect(await client.importCommitRequests.count == 1)
    }

    @Test func a413IsMappedToTooLarge() async {
        let client = FakeAPIClient()
        await client.setImportPreviewError(APIError.badStatus(413))
        let model = ImportTransactionsViewModel(client: client)

        await model.preview(Self.request())

        #expect(model.phase == .failed(.tooLarge))
    }

    @Test func a422IsMappedToBadFile() async {
        let client = FakeAPIClient()
        await client.setImportPreviewError(APIError.badStatus(422))
        let model = ImportTransactionsViewModel(client: client)

        await model.preview(Self.request())

        #expect(model.phase == .failed(.badFile))
    }

    @Test func anyOtherErrorIsGeneric() async {
        let client = FakeAPIClient()
        await client.setImportCommitError(APIError.transport(underlying: FakeAPIError()))
        let model = ImportTransactionsViewModel(client: client)

        await model.commit(Self.request())

        #expect(model.phase == .failed(.generic))
    }

    @Test func resetReturnsToIdle() async {
        let client = FakeAPIClient()
        await client.setImportPreviewResult(Self.preview(new: 1, alreadyImported: 0, invalid: 0))
        let model = ImportTransactionsViewModel(client: client)
        await model.preview(Self.request())

        model.reset()

        #expect(model.phase == .idle)
    }
}
