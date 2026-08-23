import Foundation
import Observation
import TraccioCore

/// Drives `CategorizationView`: loads categories and categorization rules
/// together, and manages categories (create, rename, delete). Creating and
/// deleting rules, and running `POST /rules/apply`, land in later slices.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`client/CLAUDE.md`). `load()` fails the whole screen if *either* fetch
/// fails: categories are not decoration here, every rule row resolves its
/// `categoryID` through them. Nothing here logs or prints a rule or
/// category: a pattern is merchant/counterparty text, a name is user-typed
/// (`.claude/rules/data-safety.md`).
@MainActor
@Observable
final class CategorizationViewModel {
    /// What the view should show right now.
    enum State {
        case idle
        case loading
        case loaded(Content)
        case failed
    }

    /// The screen's loaded data: rules in evaluation order, and every
    /// category a rule (or a confirmation) can reference.
    struct Content: Equatable {
        let rules: [RuleResponse]
        let categories: [CategoryResponse]
    }

    /// Why an action failed, for the view to surface. Carries only a
    /// status-derived reason, never the response body
    /// (`.claude/rules/data-safety.md`) — same shape as
    /// `AccountsViewModel.ActionFailure`.
    enum ActionFailure: Equatable {
        /// `DELETE /categories/{id}` refused because it is confirmed on a
        /// transaction.
        case categoryInUse(categoryID: UUID)
        /// A category create/rename collided with an existing name.
        case nameTaken
        case generic
    }

    /// Current load state, observed by the view.
    private(set) var state: State = .idle
    /// Set while a create/rename/delete call is in flight, to disable the
    /// screen's controls rather than let two actions race.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?

    /// Client used to reach the backend.
    private let client: any APIClientProtocol
    /// Called after a successful `deleteCategory(id:)` — it can change a
    /// transaction's `effectiveCategoryID` by clearing stale suggestions —
    /// so the caller can invalidate Movimenti/Panoramica (`DataFreshness`)
    /// without this view model knowing either exists.
    private let onSuggestionsChanged: () -> Void

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    /// onSuggestionsChanged:
    ///     Called after a write that can change a transaction's effective
    ///     category. Defaults to a no-op for previews and callers that don't
    ///     need it.
    init(
        client: any APIClientProtocol = APIClient.devDefault,
        onSuggestionsChanged: @escaping () -> Void = {}
    ) {
        self.client = client
        self.onSuggestionsChanged = onSuggestionsChanged
    }

    /// Fetch rules and categories together, and publish the outcome.
    ///
    /// A failure in *either* fetch surfaces as `.failed` — see the type's
    /// docstring for why categories are not best-effort on this screen.
    func load() async {
        state = .loading
        do {
            async let categoriesResult = client.categories()
            let rules = try await client.rules()
            let categories = try await categoriesResult
            state = .loaded(Content(rules: rules, categories: categories))
        } catch {
            state = .failed
        }
    }

    /// Seed the caller's default category set, for a fresh database with
    /// none yet — the rule-creation picker would otherwise dead-end.
    func seedDefaultCategories() async {
        await performUpdate { client in
            _ = try await client.seedDefaultCategories()
        }
    }

    /// Create a category.
    ///
    /// Parameters
    /// ----------
    /// name:
    ///     The category's name.
    func createCategory(name: String) async {
        await performUpdate(onFailure: { $0 == 409 ? .nameTaken : .generic }) { client in
            _ = try await client.createCategory(name: name)
        }
    }

    /// Rename a category.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to rename.
    /// name:
    ///     The new name.
    func renameCategory(id: UUID, name: String) async {
        await performUpdate(onFailure: { $0 == 409 ? .nameTaken : .generic }) { client in
            _ = try await client.renameCategory(id: id, name: name)
        }
    }

    /// Delete a category.
    ///
    /// Refused (`409`) when confirmed on any transaction — surfaced honestly
    /// as `.categoryInUse`, with no client-side workaround (merging one
    /// category into another is not built yet, `tasks/backlog.md`). On
    /// success, notifies `onSuggestionsChanged` since the backend clears
    /// every `suggested_category_id` pointing at the deleted category.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to delete.
    func deleteCategory(id: UUID) async {
        await performUpdate(
            onFailure: { $0 == 409 ? .categoryInUse(categoryID: id) : .generic },
            notifiesFreshness: true
        ) { client in
            try await client.deleteCategory(id: id)
        }
    }

    /// Shared shape for every write above: guard against overlap, run the
    /// write, reload both lists on success (never mutate them in place — see
    /// the type's docstring), and notify `onSuggestionsChanged` when asked —
    /// or map the failure to an `ActionFailure` and leave the loaded content
    /// untouched.
    ///
    /// Parameters
    /// ----------
    /// mapFailure:
    ///     Maps a failed request's HTTP status code (`nil` for a non-HTTP
    ///     failure, e.g. no connection) to the reason the view should show.
    ///     Defaults to always reporting `.generic`.
    /// notifiesFreshness:
    ///     Whether a successful write should call `onSuggestionsChanged`.
    /// write:
    ///     The write to perform, given the client.
    private func performUpdate(
        onFailure mapFailure: (Int?) -> ActionFailure = { _ in .generic },
        notifiesFreshness: Bool = false,
        _ write: (any APIClientProtocol) async throws -> Void
    ) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            try await write(client)
            await load()
            if notifiesFreshness { onSuggestionsChanged() }
        } catch APIError.badStatus(let code) {
            actionFailure = mapFailure(code)
        } catch {
            actionFailure = mapFailure(nil)
        }
    }
}
