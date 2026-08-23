import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.jsonEncoder()`, the counterpart to `jsonDecoder()`.
struct JSONCodingTests {
    @Test func encodesConfirmCategoryRequestWithExplicitSnakeCaseKey() throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = ConfirmCategoryRequest(categoryID: categoryID)

        let data = try TraccioCore.jsonEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]

        // CodingKeys spell the wire name explicitly (see ConfirmCategoryRequest),
        // so this must hold with no key-conversion strategy on the encoder.
        #expect(object?["category_id"] == categoryID.uuidString)
        #expect(object?.count == 1)
    }

    @Test func encodesCreateAdvanceRequestWithExplicitSnakeCaseKeysAndNestedParticipants() throws {
        let transactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = CreateAdvanceRequest(
            transactionID: transactionID, ownShare: 1800,
            participants: [ParticipantRequest(name: "Marco", expectedAmount: 1800)]
        )

        let data = try TraccioCore.jsonEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["transaction_id"] as? String == transactionID.uuidString)
        #expect(object?["own_share"] as? Int == 1800)
        let participants = object?["participants"] as? [[String: Any]]
        #expect(participants?.count == 1)
        #expect(participants?.first?["name"] as? String == "Marco")
        #expect(participants?.first?["expected_amount"] as? Int == 1800)
    }

    @Test func encodesCreateAdvanceRequestWithNoParticipantsAsAnEmptyArray() throws {
        let request = CreateAdvanceRequest(transactionID: UUID(), ownShare: 500)

        let data = try TraccioCore.jsonEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect((object?["participants"] as? [Any])?.isEmpty == true)
    }
}
