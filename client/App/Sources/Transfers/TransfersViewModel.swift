import Foundation
import Observation
import TraccioCore

/// Drives `TransfersView`: loads suggested transfer pairs and confirms or
/// rejects them.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`docs/engineering.md`). Nothing here logs or prints a transaction: legs
/// carry amounts and raw bank descriptions, both sensitive
/// (`docs/engineering.md`).
///
/// `GET /transfers/suggestions` embeds both legs' full `TransactionResponse`
/// in each suggestion, so `load()` is a single request — no per-leg fan-out.
@MainActor
@Observable
final class TransfersViewModel {
    /// Why a confirm/reject action failed, for the view to surface. Carries
    /// only a status-derived reason, never the response body — same shape as
    /// `TransactionDetailViewModel.ActionFailure`.
    enum ActionFailure: Equatable {
        case generic
    }

    /// Current load state, observed by the view.
    private(set) var state: LoadState<[TransferSuggestionPair]> = .idle
    /// Account id → the account, for a card's "Revolut → Isybank" line.
    /// Best-effort: a failed fetch leaves this empty rather than failing the
    /// whole screen, since the suggestions are the primary content.
    private(set) var accountsByID: [UUID: AccountResponse] = [:]
    /// Set while a confirm/reject call is in flight, to disable every card's
    /// buttons and show a spinner rather than let two actions race.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?
    /// Increments once per successful confirm — a `.sensoryFeedback(.success,
    /// trigger:)` trigger, not a count anyone reads. Deliberately not bumped
    /// on a successful reject: dismissing a suggestion is a "not this one,"
    /// not an accomplishment worth celebrating with a haptic.
    private(set) var successTick = 0

    /// Client used to reach the backend. `any APIClientProtocol` rather than
    /// the concrete `APIClient` (`docs/engineering.md`), so a test can
    /// inject a fake.
    private let client: any APIClientProtocol
    /// Called once per refreshed leg after a successful confirm, so the
    /// caller can hand each row straight to
    /// `TransactionsViewModel.replace(_:)` and update Movimenti in place.
    private let onUpdate: (TransactionResponse) -> Void
    /// Called after a successful confirm — the two legs' `effectiveAmount`
    /// go from the full amount each (double-counted) to zero each, which
    /// changes `GET /dashboard/summary`'s totals. Not called after a reject:
    /// that only records a dismissal, no `role` changes.
    private let onDashboardStale: () -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to fetch through. Defaults to a client pointed at
    ///     the local dev backend.
    /// onUpdate:
    ///     Called with the refreshed legs after a successful confirm.
    ///     Defaults to a no-op for previews and callers that don't need it.
    /// onDashboardStale:
    ///     Called after a successful confirm. Defaults to a no-op for
    ///     previews and callers that don't need it.
    init(
        client: any APIClientProtocol = APIClient.current,
        onUpdate: @escaping (TransactionResponse) -> Void = { _ in },
        onDashboardStale: @escaping () -> Void = {}
    ) {
        self.client = client
        self.onUpdate = onUpdate
        self.onDashboardStale = onDashboardStale
    }

    /// Fetch the suggestions (legs embedded) and publish the result.
    ///
    /// A failure to list suggestions is surfaced as `.failed`. A failure to
    /// fetch `accounts()` is best-effort and does not fail the screen — see
    /// `accountsByID`.
    func load() async {
        state = .loading

        let suggestions: [TransferSuggestionResponse]
        do {
            suggestions = try await client.transferSuggestions()
        } catch {
            state = .failed
            return
        }
        state = .loaded(TraccioCore.pairSuggestions(suggestions))

        if let accounts = try? await client.accounts() {
            accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        }
    }

    /// Confirm `pair` as a transfer, then drop it from the list.
    ///
    /// On success both legs are re-fetched (their `effectiveAmount` is now
    /// zero) and handed to `onUpdate`, one call per leg — `onUpdate` already
    /// matches by id, so two calls need no signature change. On failure the
    /// pair stays in the list and `actionFailure` is set.
    func confirm(_ pair: TransferSuggestionPair) async {
        await performUpdate(on: pair) { client in
            _ = try await client.confirmTransfer(
                outgoingID: pair.suggestion.outgoingTransactionID,
                incomingID: pair.suggestion.incomingTransactionID,
                kind: pair.suggestion.kind
            )
            async let outgoing = client.transaction(id: pair.suggestion.outgoingTransactionID)
            async let incoming = client.transaction(id: pair.suggestion.incomingTransactionID)
            return try await [outgoing, incoming]
        }
        if actionFailure == nil {
            onDashboardStale()
            successTick += 1
        }
    }

    /// Reject `pair` so it is not suggested again, then drop it from the
    /// list.
    ///
    /// The dismissal is persisted server-side (`POST /transfers/reject`), so
    /// a subsequent `load()` will not bring it back. No leg changes role, so
    /// there is nothing to hand to `onUpdate`.
    func reject(_ pair: TransferSuggestionPair) async {
        await performUpdate(on: pair) { client in
            try await client.rejectTransfer(
                outgoingID: pair.suggestion.outgoingTransactionID,
                incomingID: pair.suggestion.incomingTransactionID
            )
            return []
        }
    }

    /// Shared shape for `confirm(_:)` and `reject(_:)`: guard against
    /// overlap, run the write, remove `pair` from the list on success, and
    /// notify `onUpdate` with whatever refreshed rows `write` produced — or
    /// record `actionFailure` and leave the list untouched on failure.
    ///
    /// Parameters
    /// ----------
    /// pair:
    ///     The suggestion being acted on.
    /// write:
    ///     The transfer write to perform, returning the rows to hand to
    ///     `onUpdate` (empty for a reject, both legs for a confirm).
    private func performUpdate(
        on pair: TransferSuggestionPair,
        _ write: (any APIClientProtocol) async throws -> [TransactionResponse]
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            let refreshed = try await write(client)
            for transaction in refreshed { onUpdate(transaction) }
            guard case .loaded(let current) = state else { return }
            state = .loaded(current.filter { $0.id != pair.id })
        } catch {
            actionFailure = .generic
        }
    }
}
