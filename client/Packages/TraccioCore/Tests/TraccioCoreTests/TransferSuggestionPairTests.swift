import Foundation
import Testing

@testable import TraccioCore

/// Tests for `pairSuggestions(_:transactions:)` — pure, no networking.
///
/// Fixtures are synthetic (`.claude/rules/data-safety.md`): invented ids,
/// round amounts, `"TEST MERCHANT 01"`.
struct TransferSuggestionPairTests {
    private static func transaction(id: UUID, amount: Int) -> TransactionResponse {
        TransactionResponse(
            id: id,
            accountID: UUID(),
            amount: amount,
            effectiveAmount: amount,
            currency: "EUR",
            bookedAt: Date(timeIntervalSince1970: 1_755_000_000),
            valueDate: nil,
            description: "TEST MERCHANT 01",
            displayDescription: nil,
            status: .booked,
            role: .personal,
            suggestedCategoryID: nil,
            confirmedCategoryID: nil,
            effectiveCategoryID: nil,
            eventID: nil
        )
    }

    private static let outgoingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let incomingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func suggestion() -> TransferSuggestionResponse {
        TransferSuggestionResponse(
            kind: .twoSided,
            outgoingTransactionID: outgoingID,
            incomingTransactionID: incomingID,
            currency: "EUR",
            outgoingAmount: -25000,
            incomingAmount: 25000,
            amountDelta: 0,
            dayGap: 0
        )
    }

    @Test func pairsASuggestionWhoseBothLegsResolve() {
        let outgoing = Self.transaction(id: Self.outgoingID, amount: -25000)
        let incoming = Self.transaction(id: Self.incomingID, amount: 25000)

        let pairs = TraccioCore.pairSuggestions([Self.suggestion()], transactions: [outgoing, incoming])

        #expect(pairs.count == 1)
        #expect(pairs[0].outgoing.id == Self.outgoingID)
        #expect(pairs[0].incoming.id == Self.incomingID)
    }

    @Test func dropsASuggestionWhoseOutgoingLegDoesNotResolve() {
        let incoming = Self.transaction(id: Self.incomingID, amount: 25000)

        let pairs = TraccioCore.pairSuggestions([Self.suggestion()], transactions: [incoming])

        #expect(pairs.isEmpty)
    }

    @Test func dropsASuggestionWhoseIncomingLegDoesNotResolve() {
        let outgoing = Self.transaction(id: Self.outgoingID, amount: -25000)

        let pairs = TraccioCore.pairSuggestions([Self.suggestion()], transactions: [outgoing])

        #expect(pairs.isEmpty)
    }

    @Test func preservesInputOrderAndSkipsUnresolvedSuggestionsInPlace() {
        let secondOutgoingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondIncomingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let unresolvable = TransferSuggestionResponse(
            kind: .twoSided,
            outgoingTransactionID: UUID(), incomingTransactionID: UUID(),
            currency: "EUR", outgoingAmount: -100, incomingAmount: 100, amountDelta: 0, dayGap: 0
        )
        let second = TransferSuggestionResponse(
            kind: .twoSided,
            outgoingTransactionID: secondOutgoingID, incomingTransactionID: secondIncomingID,
            currency: "EUR", outgoingAmount: -500, incomingAmount: 500, amountDelta: 0, dayGap: 0
        )
        let transactions = [
            Self.transaction(id: Self.outgoingID, amount: -25000),
            Self.transaction(id: Self.incomingID, amount: 25000),
            Self.transaction(id: secondOutgoingID, amount: -500),
            Self.transaction(id: secondIncomingID, amount: 500),
        ]

        let pairs = TraccioCore.pairSuggestions(
            [Self.suggestion(), unresolvable, second], transactions: transactions
        )

        #expect(pairs.count == 2)
        #expect(pairs[0].suggestion.outgoingTransactionID == Self.outgoingID)
        #expect(pairs[1].suggestion.outgoingTransactionID == secondOutgoingID)
    }

    @Test func idIsThePairOfLegIDs() {
        let outgoing = Self.transaction(id: Self.outgoingID, amount: -25000)
        let incoming = Self.transaction(id: Self.incomingID, amount: 25000)

        let pairs = TraccioCore.pairSuggestions([Self.suggestion()], transactions: [outgoing, incoming])

        #expect(pairs[0].id == "\(Self.outgoingID.uuidString)_\(Self.incomingID.uuidString)")
    }
}
