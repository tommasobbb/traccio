import Foundation
import Testing

@testable import TraccioCore

/// Tests for `pairSuggestions(_:)` — pure, no networking.
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

    private static func suggestion(
        outgoingID: UUID = outgoingID,
        incomingID: UUID = incomingID
    ) -> TransferSuggestionResponse {
        TransferSuggestionResponse(
            kind: .twoSided,
            outgoingTransactionID: outgoingID,
            incomingTransactionID: incomingID,
            currency: "EUR",
            outgoingAmount: -25000,
            incomingAmount: 25000,
            amountDelta: 0,
            dayGap: 0,
            outgoing: transaction(id: outgoingID, amount: -25000),
            incoming: transaction(id: incomingID, amount: 25000)
        )
    }

    @Test func liftsTheEmbeddedLegsOutOfEachSuggestion() {
        let pairs = TraccioCore.pairSuggestions([Self.suggestion()])

        #expect(pairs.count == 1)
        #expect(pairs[0].outgoing.id == Self.outgoingID)
        #expect(pairs[0].incoming.id == Self.incomingID)
        #expect(pairs[0].suggestion.outgoingTransactionID == Self.outgoingID)
    }

    @Test func preservesInputOrder() {
        let secondOutgoingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondIncomingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let pairs = TraccioCore.pairSuggestions([
            Self.suggestion(),
            Self.suggestion(outgoingID: secondOutgoingID, incomingID: secondIncomingID),
        ])

        #expect(pairs.count == 2)
        #expect(pairs[0].suggestion.outgoingTransactionID == Self.outgoingID)
        #expect(pairs[1].suggestion.outgoingTransactionID == secondOutgoingID)
    }

    @Test func idIsThePairOfLegIDs() {
        let pairs = TraccioCore.pairSuggestions([Self.suggestion()])

        #expect(pairs[0].id == "\(Self.outgoingID.uuidString)_\(Self.incomingID.uuidString)")
    }
}
