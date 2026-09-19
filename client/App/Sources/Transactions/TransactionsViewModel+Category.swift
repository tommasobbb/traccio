import Foundation
import TraccioCore

/// Category confirm/clear, seeding a fresh database's default categories, and
/// creating a rule from a row's confirmed category — moved here from
/// `TransactionDetailViewModel+Category.swift` when categorizing became a
/// row-level action (`docs/decisions/0036-movimenti-row-actions.md`).
///
/// Shares one `isUpdatingRow`/`rowActionFailure` pair with
/// `TransactionsViewModel+RowActions.swift`'s advance/manual-movement writes
/// — the same shape `TransactionDetailViewModel.performUpdate` used, since
/// only one row-action sheet can be open at a time (`TransactionsView.rowAction`),
/// so there is never real overlap to distinguish.
extension TransactionsViewModel {
    /// Confirm `categoryID` on `transactionID`, then swap the refreshed row
    /// in via `replace(_:)`.
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to confirm; must belong to the caller.
    /// transactionID:
    ///     The transaction to confirm it on.
    ///
    /// Returns
    /// -------
    /// `true` if the confirm succeeded, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func confirmCategory(_ categoryID: UUID, for transactionID: UUID) async -> Bool {
        await performRowUpdate(for: transactionID) {
            try await $0.confirmCategory(transactionID: $1, categoryID: categoryID)
        }
    }

    /// Clear `transactionID`'s confirmed category, then swap the refreshed
    /// row in via `replace(_:)`.
    ///
    /// Returns
    /// -------
    /// `true` if the clear succeeded, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func clearCategory(for transactionID: UUID) async -> Bool {
        await performRowUpdate(for: transactionID) { try await $0.clearCategory(transactionID: $1) }
    }

    /// Seed the caller's default category set, for a fresh database with none
    /// yet — the picker would otherwise dead-end.
    ///
    /// Returns
    /// -------
    /// `true` if the seed succeeded, `false` otherwise (having recorded
    /// `rowActionFailure`).
    @discardableResult
    func seedDefaultCategories() async -> Bool {
        guard beginRowAction() else { return false }

        do {
            let seeded = try await client.seedDefaultCategories()
            setCategories(seeded)
            endRowAction(failure: nil)
            return true
        } catch {
            endRowAction(failure: .generic)
            return false
        }
    }

    /// Create a categorization rule, then re-apply every rule so this (and
    /// any other matching) transaction picks up the resulting suggestion —
    /// "categorizza sempre così" from `CreateRuleFromTransactionSheet`. Unlike
    /// `confirmCategory`/`clearCategory`, applying rules can change any row's
    /// `effectiveCategoryID`, not just this one, so the caller reloads the
    /// page (`DataFreshness.Scope.transactions`) on success rather than this
    /// method trying to know which rows changed.
    ///
    /// A `409` from the create means a rule with this exact
    /// `(matchKind, pattern)` already exists — surfaced as `.duplicateRule`,
    /// distinct from `.generic`. `pattern` is never put in a log or error
    /// message (`docs/engineering.md`: it is merchant/counterparty text
    /// lifted from the bank description).
    ///
    /// Parameters
    /// ----------
    /// categoryID:
    ///     The category to assign whenever this rule matches — always the
    ///     transaction's confirmed category, since the sheet only opens once
    ///     one exists.
    /// matchKind:
    ///     The predicate to apply to a transaction's description.
    /// pattern:
    ///     The text to match against.
    ///
    /// Returns
    /// -------
    /// `true` if the rule was created and applied, `false` otherwise (having
    /// recorded `rowActionFailure`).
    @discardableResult
    func createRuleAndApplyRules(
        categoryID: UUID, matchKind: RuleMatchKind, pattern: String
    ) async -> Bool {
        guard beginRowAction() else { return false }

        do {
            _ = try await client.createRule(
                CreateRuleRequest(categoryID: categoryID, matchKind: matchKind, pattern: pattern)
            )
            _ = try await client.applyRules()
            endRowAction(failure: nil)
            markRowActionSucceeded()
            return true
        } catch APIError.badStatus(409) {
            endRowAction(failure: .duplicateRule)
            return false
        } catch {
            endRowAction(failure: .generic)
            return false
        }
    }
}
