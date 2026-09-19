import Foundation
import TraccioCore

/// Category confirm/clear, seeding a fresh database's default categories, and
/// creating a rule from this transaction's confirmed category.
extension TransactionDetailViewModel {
    /// Fetch categories if none were seeded at `init`.
    ///
    /// A no-op when `categories` is already non-empty — the common case,
    /// since `TransactionsViewModel` fetches them for every row's label
    /// before a detail screen is ever reached. Failure leaves `categories`
    /// empty; the view falls back to the "seed defaults" affordance.
    func loadCategoriesIfNeeded() async {
        guard categories.isEmpty else { return }
        if let fetched = try? await client.categories() {
            categories = fetched
        }
    }

    /// Seed the caller's default category set, for a fresh database with none
    /// yet — the picker would otherwise dead-end.
    func seedDefaultCategories() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            categories = try await client.seedDefaultCategories()
        } catch {
            actionFailure = .generic
        }
    }

    /// Confirm `categoryID` on the transaction, then re-fetch it.
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    func confirm(categoryID: UUID) async {
        await performUpdate { try await $0.confirmCategory(transactionID: $1, categoryID: categoryID) }
    }

    /// Clear the transaction's confirmed category, then re-fetch it.
    func clearCategory() async {
        await performUpdate { try await $0.clearCategory(transactionID: $1) }
    }

    /// Create a categorization rule, then re-apply every rule so this (and
    /// any other matching) transaction picks up the resulting suggestion
    /// immediately — "categorizza sempre così" from
    /// `CreateRuleFromTransactionSheet`.
    ///
    /// A `409` from the create means a rule with this exact
    /// `(matchKind, pattern)` already exists — surfaced as `.duplicateRule`,
    /// distinct from `.generic`. `pattern` is never put in a log or error
    /// message (`docs/engineering.md`: it is merchant/counterparty
    /// text lifted from the bank description).
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to assign whenever this rule matches — always this
    ///     transaction's confirmed category, since the sheet only opens once
    ///     one exists.
    /// matchKind:
    ///     The predicate to apply to a transaction's description.
    /// pattern:
    ///     The text to match against.
    func createRuleAndApplyRules(categoryID: UUID, matchKind: RuleMatchKind, pattern: String) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        actionFailure = nil

        do {
            _ = try await client.createRule(
                CreateRuleRequest(categoryID: categoryID, matchKind: matchKind, pattern: pattern)
            )
            _ = try await client.applyRules()
            onRulesApplied()
            successTick += 1
        } catch APIError.badStatus(409) {
            actionFailure = .duplicateRule
        } catch {
            actionFailure = .generic
        }
    }
}
