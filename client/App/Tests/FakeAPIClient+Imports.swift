import Foundation
import TraccioCore

/// `ImportsAPI` stub, mirroring `APIClient+Imports.swift`.
extension FakeAPIClient {
    func setImportPreviewResult(_ response: ImportPreviewResponse) {
        importPreviewToReturn = response
    }

    func setImportPreviewError(_ error: Error) {
        importPreviewError = error
    }

    func setImportCommitResult(_ response: ImportCommitResponse) {
        importCommitToReturn = response
    }

    func setImportCommitError(_ error: Error) {
        importCommitError = error
    }

    func importPreview(_ request: ImportPreviewRequest) async throws -> ImportPreviewResponse {
        if let importPreviewError { throw importPreviewError }
        importPreviewRequests.append(request)
        guard let importPreviewToReturn else { throw NotConfigured() }
        return importPreviewToReturn
    }

    func importCommit(_ request: ImportPreviewRequest) async throws -> ImportCommitResponse {
        if let importCommitError { throw importCommitError }
        importCommitRequests.append(request)
        guard let importCommitToReturn else { throw NotConfigured() }
        return importCommitToReturn
    }
}
