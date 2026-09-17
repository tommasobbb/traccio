import Foundation
import Observation
import TraccioCore

/// Drives `CategorizationView`: manages categories and categorization
/// rules, and runs `POST /rules/apply`.
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
        /// A rule create collided with an existing `(matchKind, pattern)`.
        case duplicateRule
        /// A rule's pattern was blank or too long.
        case invalidPattern
        case generic
    }

    /// Current load state, observed by the view.
    private(set) var state: LoadState<Content> = .idle
    /// Set while a create/rename/delete call is in flight, to disable the
    /// screen's controls rather than let two actions race.
    private(set) var isUpdating = false
    /// The most recent action failure, if any, for the view to surface.
    private(set) var actionFailure: ActionFailure?
    /// The most recent `POST /rules/apply` result, kept across a subsequent
    /// `load()` so the footer's count line survives a pull-to-refresh.
    /// Untouched on a failed apply — see `ApplyRulesResponse`'s docstring for
    /// why this is a state sentence ("N movimenti su M hanno un
    /// suggerimento"), never a change count.
    private(set) var lastApplyResult: ApplyRulesResponse?

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
        client: any APIClientProtocol = APIClient.current,
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

    /// Create a category, optionally as a child of an existing root.
    ///
    /// Parameters
    /// ----------
    /// name:
    ///     The category's name.
    /// parentID:
    ///     The root to nest under, or `nil` to create a root.
    /// color:
    ///     The category's colour.
    /// icon:
    ///     The category's icon, or `nil` to leave it unset.
    func createCategory(
        name: String, parentID: UUID?, color: PaletteColor, icon: CategoryIcon?
    ) async {
        await performUpdate(onFailure: { $0 == 409 ? .nameTaken : .generic }) { client in
            _ = try await client.createCategory(
                name: name, parentID: parentID, color: color, icon: icon
            )
        }
    }

    /// Rename a category (its name only — colour and icon go through
    /// `setCategoryAppearance`, so a rename never resets either).
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

    /// Set a category's colour and icon.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to restyle.
    /// color:
    ///     The new colour.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    func setCategoryAppearance(id: UUID, color: PaletteColor, icon: CategoryIcon?) async {
        await performUpdate { client in
            _ = try await client.setCategoryAppearance(id: id, color: color, icon: icon)
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

    /// Create a categorization rule.
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to assign when this rule matches.
    /// matchKind:
    ///     The predicate to apply to a transaction's description.
    /// pattern:
    ///     The text to match against.
    func createRule(categoryID: UUID, matchKind: RuleMatchKind, pattern: String) async {
        await performUpdate(onFailure: { code in
            switch code {
            case 409: return .duplicateRule
            case 422: return .invalidPattern
            default: return .generic
            }
        }) { client in
            _ = try await client.createRule(
                CreateRuleRequest(categoryID: categoryID, matchKind: matchKind, pattern: pattern)
            )
        }
    }

    /// Delete a categorization rule.
    ///
    /// Does not notify `onSuggestionsChanged`: deleting a rule's definition
    /// leaves every transaction's `suggested_category_id` exactly as it was
    /// until the next `applyRules()` recomputes it (ADR 0005).
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The rule to delete.
    func deleteRule(id: UUID) async {
        await performUpdate { client in
            try await client.deleteRule(id: id)
        }
    }

    /// Recompute every rule against every transaction.
    ///
    /// A large, undoable write over the whole transaction pool (ADR 0005: a
    /// full recompute, not incremental) — the view gates this behind an
    /// explicit confirmation, not a casual tap. On success, publishes the
    /// counts and notifies `onSuggestionsChanged`.
    func applyRules() async {
        await performUpdate(notifiesFreshness: true) { client in
            let result = try await client.applyRules()
            self.lastApplyResult = result
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
