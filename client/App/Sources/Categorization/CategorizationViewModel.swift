import Foundation
import Observation
import TraccioCore

/// Drives `CategorizationView`: manages categories and categorization
/// rules, and runs `POST /rules/apply`.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`docs/engineering.md`). `load()` fails the whole screen if *either* fetch
/// fails: categories are not decoration here, every rule row resolves its
/// `categoryID` through them. Nothing here logs or prints a rule or
/// category: a pattern is merchant/counterparty text, a name is user-typed
/// (`docs/engineering.md`).
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
    /// (`docs/engineering.md`) — same shape as
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
        /// `POST /categories/{id}/move` refused because the category being
        /// moved has children of its own and a non-`nil` parent was given.
        case categoryHasChildren
        /// `POST /categories/{id}/move` refused because the new parent is
        /// the category itself or is itself a child (max depth is 2, ADR
        /// 0018) — pre-checked client-side for the children case, but the
        /// self/depth cases still round-trip.
        case invalidMove
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

    /// Apply a category edit — name, colour, and icon — as one logical write.
    ///
    /// Not atomic server-side: there is no combined update endpoint, so this
    /// is still `POST /categories/{id}/rename` followed by
    /// `POST /categories/{id}/appearance` when either actually changed. What
    /// it guarantees is one in-flight guard, one failure mapping, and one
    /// `load()` for the whole edit, instead of the view issuing two
    /// independent writes and two reloads. Each write is skipped when its
    /// fields are unchanged, so renaming nothing never risks a spurious
    /// `409 category_name_taken` from re-sending the same name. If the
    /// rename lands and the appearance write fails, the rename stays — the
    /// subsequent `load()` shows exactly what persisted, alongside the
    /// failure banner.
    ///
    /// Parameters
    /// ----------
    /// category:
    ///     The category being edited, before this write.
    /// name:
    ///     The new name.
    /// color:
    ///     The new colour.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    func updateCategory(
        _ category: CategoryResponse, name: String, color: PaletteColor, icon: CategoryIcon?
    ) async {
        await performUpdate(onFailure: { $0 == 409 ? .nameTaken : .generic }) { client in
            if name != category.name {
                _ = try await client.renameCategory(id: category.id, name: name)
            }
            if color != category.color || icon != category.icon {
                _ = try await client.setCategoryAppearance(id: category.id, color: color, icon: icon)
            }
        }
    }

    /// Reparent a category — nest it under a root, or (`parentID: nil`) make
    /// it a root.
    ///
    /// Wires `POST /categories/{id}/move`, present since ADR 0018 and until
    /// now unused by any view. Notifies `onSuggestionsChanged`: the
    /// dashboard's category breakdown rolls a child's spending up into its
    /// root, so a move changes what Panoramica shows even though no
    /// transaction changed.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to move.
    /// parentID:
    ///     The new parent, or `nil` to make it a root.
    func moveCategory(id: UUID, parentID: UUID?) async {
        await performUpdate(
            onFailure: { code in
                switch code {
                case 409: return .categoryHasChildren
                case 422: return .invalidMove
                default: return .generic
                }
            },
            notifiesFreshness: true
        ) { client in
            _ = try await client.moveCategory(id: id, parentID: parentID)
        }
    }

    /// Apply a rule edit.
    ///
    /// Implemented as delete-then-create, which is not a workaround: a rule
    /// has no edit endpoint by design (ADR 0005) — its `(matchKind,
    /// pattern)` pair is what makes it a distinct rule at all, so "editing"
    /// one is delete-and-recreate by the backend's own stated semantics
    /// (`RuleResponse`'s doc comment, `APIClient+Rules.deleteRule`'s).
    /// Nothing persists a rule id outside this screen — a suggestion stores
    /// only `category_id` — so the churn is invisible elsewhere. Its one
    /// visible consequence: `created_at` changes, so among rules with
    /// *equal-length* patterns the edited rule now sorts last in evaluation
    /// order (ties break by `created_at`); precedence is driven by pattern
    /// length, so this is harmless.
    ///
    /// **Delete must come first.** Create-first would `409` whenever
    /// `(matchKind, pattern)` is unchanged — the commonest edit, "just point
    /// it at a different category" — because the backend's duplicate check
    /// is keyed on that pair alone and ignores the category. On a failed
    /// create, the original is recreated verbatim, so a failed edit leaves
    /// the rule set exactly as it was rather than silently losing a rule.
    ///
    /// Parameters
    /// ----------
    /// original:
    ///     The rule being edited, before this write.
    /// categoryID:
    ///     The (possibly unchanged) target category.
    /// matchKind:
    ///     The (possibly unchanged) predicate.
    /// pattern:
    ///     The (possibly unchanged) pattern.
    func updateRule(
        _ original: RuleResponse, categoryID: UUID, matchKind: RuleMatchKind, pattern: String
    ) async {
        guard categoryID != original.categoryID || matchKind != original.matchKind
            || pattern != original.pattern
        else { return }

        await performUpdate(onFailure: { code in
            switch code {
            case 409: return .duplicateRule
            case 422: return .invalidPattern
            default: return .generic
            }
        }) { client in
            try await client.deleteRule(id: original.id)
            do {
                _ = try await client.createRule(
                    CreateRuleRequest(categoryID: categoryID, matchKind: matchKind, pattern: pattern)
                )
            } catch {
                _ = try? await client.createRule(
                    CreateRuleRequest(
                        categoryID: original.categoryID, matchKind: original.matchKind,
                        pattern: original.pattern
                    )
                )
                throw error
            }
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
