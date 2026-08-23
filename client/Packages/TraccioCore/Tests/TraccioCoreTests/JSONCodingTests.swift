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
}
