import Foundation
import TraccioCore

/// `RulesAPI` stub, mirroring `APIClient+Rules.swift`.
extension FakeAPIClient {
    func setRules(_ rules: [RuleResponse]) {
        rulesToReturn = rules
    }

    func setRulesError(_ error: Error) {
        rulesError = error
    }

    func setCreateRuleResult(_ rule: RuleResponse) {
        createRuleToReturn = rule
    }

    func setCreateRuleError(_ error: Error) {
        createRuleError = error
    }

    func setDeleteRuleError(_ error: Error) {
        deleteRuleError = error
    }

    func setApplyRulesResult(_ result: ApplyRulesResponse) {
        applyRulesToReturn = result
    }

    func setApplyRulesError(_ error: Error) {
        applyRulesError = error
    }

    func rules() async throws -> [RuleResponse] {
        rulesFetchCount += 1
        if let rulesError { throw rulesError }
        return rulesToReturn
    }

    func createRule(_ request: CreateRuleRequest) async throws -> RuleResponse {
        if let createRuleError { throw createRuleError }
        createdRuleRequests.append(request)
        guard let createRuleToReturn else { throw NotConfigured() }
        return createRuleToReturn
    }

    func deleteRule(id: UUID) async throws {
        if let deleteRuleError { throw deleteRuleError }
        deletedRuleIDs.append(id)
    }

    func applyRules() async throws -> ApplyRulesResponse {
        applyRulesCallCount += 1
        if let applyRulesError { throw applyRulesError }
        return applyRulesToReturn
    }
}
