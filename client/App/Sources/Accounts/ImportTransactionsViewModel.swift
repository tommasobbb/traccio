import Foundation
import Observation
import TraccioCore

/// Drives `ImportTransactionsSheet`: runs `POST /imports/preview` then
/// `POST /imports/commit` for a chosen file, account(s), and profile (ADR
/// 0023).
///
/// All it does is call `APIClient` and hold the outcome — no derivation
/// (`client/CLAUDE.md`). Nothing here logs the file or a movement: both carry
/// amounts and descriptions (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class ImportTransactionsViewModel {
    /// A file the user chose, already read and base64-encoded so the sheet
    /// stays free of file I/O.
    struct PickedFile: Equatable, Sendable {
        let name: String
        let base64: String
        let byteCount: Int
    }

    /// Why reading the picked file failed.
    enum FileLoadFailure: Error, Equatable, Sendable {
        /// Over `maxFileBytes` — caught here rather than reading an
        /// arbitrarily large file fully into memory to base64-encode it.
        case tooLarge
        /// The file could not be opened or read.
        case unreadable
    }

    /// A local sanity ceiling, not a mirror of `Settings.import_max_bytes`
    /// (ADR 0023) — the two used to share a value, which meant raising the
    /// backend's limit silently left the client still rejecting a file the
    /// server would have accepted. The server's `413` (`Failure.tooLarge`
    /// below) is the single source of truth for what's actually too large;
    /// this constant only guards against reading a pathologically huge file
    /// into memory before that round-trip. `nonisolated`: a plain `Int`
    /// constant needs no actor isolation, and `read(at:)` (run off the main
    /// actor in a detached task) reads it.
    nonisolated static let maxFileBytes = 50 * 1024 * 1024

    /// Where the flow is right now.
    enum Phase: Equatable {
        case idle
        /// A preview or commit call is in flight.
        case working
        /// A preview resolved; the sheet shows the rows and a "Importa" button.
        case previewed(ImportPreviewResponse)
        /// A commit resolved; the caller should reload and dismiss.
        case committed(ImportCommitResponse)
        /// Something failed; the sheet shows `failure` and lets the user retry.
        case failed(Failure)
    }

    /// Why preview or commit failed, mapped from the HTTP status. Coarser than
    /// the backend's reason codes — `APIError.badStatus` carries only the
    /// code — but the sheet pre-empts the distinguishable cases (it requires a
    /// voucher account for Satispay, offers only manual accounts, and checks
    /// the file size) so the residue is genuinely "wrong file for this
    /// profile" or a transport failure.
    enum Failure: Equatable {
        /// `413` — the file is over the server's size limit.
        case tooLarge
        /// `422` — an undecodable file, the wrong columns for the profile, or
        /// an unknown profile.
        case badFile
        /// Anything else (transport, `5xx`, an unexpected status).
        case generic
    }

    private(set) var phase: Phase = .idle
    /// The file the user last picked, or `nil` before any pick or after
    /// `reset()`.
    private(set) var pickedFile: PickedFile?
    /// Why `loadFile` last failed; `nil` once a pick succeeds.
    private(set) var fileLoadFailure: FileLoadFailure?

    private let client: any APIClientProtocol

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
    }

    /// Reset to the initial state — used when the file or a picker changes, so
    /// a stale preview never lingers under a new selection.
    ///
    /// Leaves `pickedFile` untouched: the caller resets the preview whenever
    /// an account/profile selection changes, but the picked file itself only
    /// changes via a fresh `loadFile`.
    func reset() {
        phase = .idle
    }

    /// Read, size-check, and base64-encode the file at `url`, publishing
    /// `pickedFile` or `fileLoadFailure`.
    ///
    /// The actual disk read runs off the main actor (`Task.detached`) — `url`
    /// can be a security-scoped URL from `.fileImporter` (e.g. iCloud Drive),
    /// which may take a while to materialize, and base64-encoding a
    /// multi-megabyte file is not free either. Neither belongs on the main
    /// thread (`.claude/rules/swift.md`).
    func loadFile(at url: URL) async {
        phase = .idle
        pickedFile = nil
        fileLoadFailure = nil
        switch await Task.detached(priority: .userInitiated, operation: { Self.read(at: url) }).value {
        case .success(let file):
            pickedFile = file
        case .failure(let failure):
            fileLoadFailure = failure
        }
    }

    /// Off-main-actor: opens the security scope, reads the file, and encodes
    /// it. `nonisolated` so `Task.detached` truly runs it off the main actor
    /// rather than merely queuing it there.
    nonisolated private static func read(at url: URL) -> Result<PickedFile, FileLoadFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard data.count <= maxFileBytes else { return .failure(.tooLarge) }
        return .success(
            PickedFile(name: url.lastPathComponent, base64: data.base64EncodedString(), byteCount: data.count)
        )
    }

    /// Run a preview for `request`, publishing the classified rows or a
    /// failure. A no-op while another call is in flight.
    func preview(_ request: ImportPreviewRequest) async {
        guard phase != .working else { return }
        phase = .working
        do {
            phase = .previewed(try await client.importPreview(request))
        } catch {
            phase = .failed(Self.failure(from: error))
        }
    }

    /// Commit `request`, publishing the insert counts or a failure. A no-op
    /// while another call is in flight.
    func commit(_ request: ImportPreviewRequest) async {
        guard phase != .working else { return }
        phase = .working
        do {
            phase = .committed(try await client.importCommit(request))
        } catch {
            phase = .failed(Self.failure(from: error))
        }
    }

    private static func failure(from error: any Error) -> Failure {
        switch error {
        case APIError.badStatus(413): .tooLarge
        case APIError.badStatus(422): .badFile
        default: .generic
        }
    }
}
