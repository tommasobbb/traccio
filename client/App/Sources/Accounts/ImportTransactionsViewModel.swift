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
    func reset() {
        phase = .idle
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
