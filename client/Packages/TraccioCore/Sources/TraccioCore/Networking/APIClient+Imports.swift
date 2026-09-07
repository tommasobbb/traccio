import Foundation

// File-import endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Preview a file import without writing anything (ADR 0023).
    ///
    /// Mirrors `POST /imports/preview`. Every movement the file would create is
    /// classified `new` / `alreadyImported` / `invalid`; nothing is inserted.
    /// A `413` if the file is over the size limit; a `422` for a bad profile,
    /// missing columns, an undecodable file, or a needed-but-absent voucher
    /// account; a `409 account_not_manual` for a synced target account.
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The target account(s), profile, filename, and base64 file content.
    ///
    /// Returns
    /// -------
    /// The per-movement classification and the counts.
    public func importPreview(
        _ request: ImportPreviewRequest
    ) async throws -> ImportPreviewResponse {
        try await post("imports/preview", body: request)
    }

    /// Commit a file import, inserting only the `new` movements (ADR 0023).
    ///
    /// Mirrors `POST /imports/commit` — same body and validation as
    /// `importPreview(_:)`. Running it twice on the same file adds nothing the
    /// second time (each movement's key is `"{profile}:{external_id}"`).
    ///
    /// Parameters
    /// ----------
    /// request:
    ///     The same body a preview takes.
    ///
    /// Returns
    /// -------
    /// How many movements were inserted, skipped as already present, and how
    /// many source rows were invalid.
    public func importCommit(
        _ request: ImportPreviewRequest
    ) async throws -> ImportCommitResponse {
        try await post("imports/commit", body: request)
    }
}
