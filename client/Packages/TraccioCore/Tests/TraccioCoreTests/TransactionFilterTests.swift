import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TransactionFilter.queryItems` — the pure translation
/// `APIClient.transactions(filter:limit:offset:)` relies on, so it's tested
/// standalone rather than only indirectly through a transport stub.
struct TransactionFilterTests {
    @Test func noneProducesNoQueryItems() {
        #expect(TransactionFilter.none.queryItems.isEmpty)
    }

    @Test func accountIDProducesOneItem() {
        let accountID = UUID()
        let items = TransactionFilter(accountID: accountID).queryItems
        #expect(items == [URLQueryItem(name: "account_id", value: accountID.uuidString)])
    }

    @Test func eventIDProducesOneItem() {
        let eventID = UUID()
        let items = TransactionFilter(eventID: eventID).queryItems
        #expect(items == [URLQueryItem(name: "event_id", value: eventID.uuidString)])
    }

    @Test func categoryAnyProducesNoItem() {
        #expect(TransactionFilter(category: .any).queryItems.isEmpty)
    }

    @Test func categoryUncategorizedProducesTheUncategorizedFlag() {
        let items = TransactionFilter(category: .uncategorized).queryItems
        #expect(items == [URLQueryItem(name: "uncategorized", value: "true")])
    }

    @Test func categorySomeProducesCategoryID() {
        let categoryID = UUID()
        let items = TransactionFilter(category: .some(categoryID)).queryItems
        #expect(items == [URLQueryItem(name: "category_id", value: categoryID.uuidString)])
    }

    @Test func everyFieldCombinesIntoAllThreeItems() {
        let accountID = UUID()
        let eventID = UUID()
        let categoryID = UUID()
        let items = TransactionFilter(
            accountID: accountID, eventID: eventID, category: .some(categoryID)
        ).queryItems
        #expect(
            items == [
                URLQueryItem(name: "account_id", value: accountID.uuidString),
                URLQueryItem(name: "event_id", value: eventID.uuidString),
                URLQueryItem(name: "category_id", value: categoryID.uuidString),
            ]
        )
    }
}
