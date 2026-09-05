import Foundation
import Testing

@testable import TraccioCore

/// Tests for `APIClient` that never touch the network.
///
/// A `URLProtocol` stub is registered on an ephemeral session and returns a
/// canned response for each request, so these exercise the real request /
/// status-check / decode path deterministically. Fixtures are synthetic — the
/// DTOs carry no IBANs or amounts anyway.
///
/// The suite is `.serialized`: the stub's handler is process-global mutable
/// state, so running these cases in parallel would let one test's handler
/// answer another's request.
@Suite(.serialized)
struct APIClientTests {
    /// A representative `GET /accounts` envelope: two accounts, oldest first.
    private static let accountsEnvelope = """
        {
          "accounts": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "source": "synced",
              "kind": "current",
              "currency": "EUR",
              "name": "Test Current",
              "created_at": "2026-08-10T09:30:00.123456+00:00"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "connection_id": "22222222-2222-2222-2222-222222222222",
              "source": "synced",
              "kind": "card",
              "currency": "EUR",
              "name": null,
              "created_at": "2026-08-11T10:00:00"
            }
          ]
        }
        """

    /// Build an `APIClient` whose session answers every request with `handler`.
    private static func makeClient(
        apiToken: String? = nil,
        handler: @escaping StubURLProtocol.Handler
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.setHandler(handler)
        return APIClient(baseURL: URL(string: "http://localhost:8000")!, apiToken: apiToken, session: session)
    }

    @Test func accountsDecodesEnvelopeInOrder() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/accounts")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.accountsEnvelope.utf8))
        }

        let accounts = try await client.accounts()

        #expect(accounts.count == 2)
        #expect(accounts[0].id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(accounts[0].kind == .current)
        #expect(accounts[1].kind == .card)
        #expect(accounts[1].name == nil)
    }

    @Test func renameAccountPostsToTheRenameEndpointAndDecodesTheDisplayName() async throws {
        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/accounts/\(accountID.uuidString)/rename")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["alias"] == "My salary account")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(accountID.uuidString)",
                  "connection_id": "22222222-2222-2222-2222-222222222222",
                  "source": "synced",
                  "kind": "current", "currency": "EUR", "name": "TEST CURRENT 01",
                  "alias": "My salary account", "display_name": "My salary account",
                  "color": null, "icon": null,
                  "created_at": "2026-08-25T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let account = try await client.renameAccount(id: accountID, alias: "My salary account")
        #expect(account.alias == "My salary account")
        #expect(account.displayName == "My salary account")
    }

    @Test func renameAccountWithNilAliasSendsExplicitNull() async throws {
        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            // A JSON `null` round-trips through `JSONSerialization` as
            // `NSNull`, not a missing key — this is what proves the client
            // sent an explicit `"alias": null` rather than omitting the field.
            #expect(body?["alias"] is NSNull)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(accountID.uuidString)",
                  "connection_id": "22222222-2222-2222-2222-222222222222",
                  "source": "synced",
                  "kind": "current", "currency": "EUR", "name": "TEST CURRENT 01",
                  "alias": null, "display_name": "TEST CURRENT 01",
                  "color": null, "icon": null,
                  "created_at": "2026-08-25T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let account = try await client.renameAccount(id: accountID, alias: nil)
        #expect(account.alias == nil)
        #expect(account.displayName == "TEST CURRENT 01")
    }

    @Test func setAccountAppearancePostsColorAndIconAndDecodesThem() async throws {
        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/accounts/\(accountID.uuidString)/appearance")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["color"] == "teal")
            #expect(body?["icon"] == "savings")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(accountID.uuidString)",
                  "connection_id": "22222222-2222-2222-2222-222222222222",
                  "source": "synced",
                  "kind": "current", "currency": "EUR", "name": "TEST CURRENT 01",
                  "alias": null, "display_name": "TEST CURRENT 01",
                  "color": "teal", "icon": "savings",
                  "created_at": "2026-08-25T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let account = try await client.setAccountAppearance(
            id: accountID, color: .teal, icon: .savings
        )
        #expect(account.color == .teal)
        #expect(account.icon == .savings)
    }

    @Test func setAccountAppearanceWithNilValuesSendsExplicitNulls() async throws {
        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            // Both keys must be explicit JSON `null`, not omitted — the
            // backend requires them present (mandatory-but-nullable), and
            // Swift's synthesized encoder would otherwise silently drop a
            // `nil` Optional field. See `SetAccountAppearanceRequest`'s doc
            // comment.
            #expect(body?["color"] is NSNull)
            #expect(body?["icon"] is NSNull)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(accountID.uuidString)",
                  "connection_id": "22222222-2222-2222-2222-222222222222",
                  "source": "synced",
                  "kind": "current", "currency": "EUR", "name": "TEST CURRENT 01",
                  "alias": null, "display_name": "TEST CURRENT 01",
                  "color": null, "icon": null,
                  "created_at": "2026-08-25T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let account = try await client.setAccountAppearance(id: accountID, color: nil, icon: nil)
        #expect(account.color == nil)
        #expect(account.icon == nil)
    }

    @Test func authorizationHeaderIsSentWhenAnApiTokenIsConfigured() async throws {
        let client = Self.makeClient(apiToken: "TEST-TOKEN-01") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-TOKEN-01")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.accountsEnvelope.utf8))
        }

        _ = try await client.accounts()
    }

    @Test func authorizationHeaderIsOmittedWhenNoApiTokenIsConfigured() async throws {
        let client = Self.makeClient { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.accountsEnvelope.utf8))
        }

        _ = try await client.accounts()
    }

    @Test func unauthorizedStatusThrowsUnauthorizedRatherThanBadStatus() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        await #expect {
            try await client.accounts()
        } throws: { error in
            guard case APIError.unauthorized = error else { return false }
            return true
        }
    }

    @Test func nonSuccessStatusThrowsBadStatus() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        await #expect {
            try await client.accounts()
        } throws: { error in
            guard case APIError.badStatus(500) = error else { return false }
            return true
        }
    }

    @Test func malformedBodyThrowsDecoding() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("not json".utf8))
        }

        await #expect {
            try await client.accounts()
        } throws: { error in
            guard case APIError.decoding = error else { return false }
            return true
        }
    }

    /// A representative `GET /dashboard/summary` envelope: one currency.
    private static let dashboardEnvelope = """
        { "currencies": [
          {
            "currency": "EUR", "spending": 124050, "income": 210000, "net": 85950,
            "transaction_count": 42, "average_daily_spending": null,
            "by_category": [], "by_bucket": [], "by_account": [], "comparison": null
          }
        ] }
        """

    @Test func dashboardSummaryEncodesBothBoundsAsQueryItems() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(request.url?.path == "/dashboard/summary")
            #expect(query.contains("start=2026-08-01"))
            #expect(query.contains("end=2026-09-01"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.dashboardEnvelope.utf8))
        }

        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 8; startComponents.day = 1
        startComponents.timeZone = TimeZone(identifier: "UTC")
        var endComponents = DateComponents()
        endComponents.year = 2026; endComponents.month = 9; endComponents.day = 1
        endComponents.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .iso8601)
        let start = calendar.date(from: startComponents)!
        let end = calendar.date(from: endComponents)!

        let summary = try await client.dashboardSummary(start: start, end: end)
        #expect(summary.currencies.first?.currency == "EUR")
    }

    @Test func dashboardSummaryOmitsTheQueryStringWhenBothBoundsAreNil() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/dashboard/summary")
            #expect(request.url?.query == nil)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.dashboardEnvelope.utf8))
        }

        _ = try await client.dashboardSummary()
    }

    @Test func dashboardSummaryEncodesGranularityTzAndComparisonBoundsAsQueryItems() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("granularity=month"))
            #expect(query.contains("tz=Europe%2FRome") || query.contains("tz=Europe/Rome"))
            #expect(query.contains("compare_start=2026-07-01"))
            #expect(query.contains("compare_end=2026-08-01"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.dashboardEnvelope.utf8))
        }

        var compareStartComponents = DateComponents()
        compareStartComponents.year = 2026; compareStartComponents.month = 7
        compareStartComponents.day = 1
        compareStartComponents.timeZone = TimeZone(identifier: "UTC")
        var compareEndComponents = DateComponents()
        compareEndComponents.year = 2026; compareEndComponents.month = 8; compareEndComponents.day = 1
        compareEndComponents.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .iso8601)
        let compareStart = calendar.date(from: compareStartComponents)!
        let compareEnd = calendar.date(from: compareEndComponents)!

        _ = try await client.dashboardSummary(
            granularity: .month, tz: "Europe/Rome", compareStart: compareStart, compareEnd: compareEnd
        )
    }

    @Test func dashboardSummaryOmitsGranularityWhenItIsTheDefault() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(!query.contains("granularity"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.dashboardEnvelope.utf8))
        }

        _ = try await client.dashboardSummary(granularity: .day)
    }

    /// A representative `GET /transactions` envelope: one transaction.
    private static let transactionsEnvelope = """
        { "transactions": [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "account_id": "22222222-2222-2222-2222-222222222222",
            "amount": -1230,
            "effective_amount": -1230,
            "currency": "EUR",
            "booked_at": "2026-08-20T09:30:00+00:00",
            "value_date": null,
            "description": "TEST MERCHANT 01",
            "display_description": null,
            "status": "booked",
            "role": "personal",
            "suggested_category_id": null,
            "confirmed_category_id": null,
            "effective_category_id": null
          }
        ] }
        """

    @Test func transactionsEncodesLimitOffsetAndAccountID() async throws {
        let accountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(request.url?.path == "/transactions")
            #expect(query.contains("limit=25"))
            #expect(query.contains("offset=50"))
            #expect(query.contains("account_id=\(accountID.uuidString)"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        let transactions = try await client.transactions(
            filter: TransactionFilter(accountID: accountID), limit: 25, offset: 50
        )
        #expect(transactions.count == 1)
        #expect(transactions[0].amount == -1230)
    }

    @Test func transactionsOmitsEveryFilterParamWhenFilterIsNone() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(!query.contains("account_id"))
            #expect(!query.contains("event_id"))
            #expect(!query.contains("category_id"))
            #expect(!query.contains("uncategorized"))
            #expect(query.contains("limit=50"))
            #expect(query.contains("offset=0"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        _ = try await client.transactions()
    }

    @Test func transactionsEncodesEventID() async throws {
        let eventID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("event_id=\(eventID.uuidString)"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        _ = try await client.transactions(filter: TransactionFilter(eventID: eventID))
    }

    @Test func transactionsEncodesCategoryID() async throws {
        let categoryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("category_id=\(categoryID.uuidString)"))
            #expect(!query.contains("uncategorized"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        _ = try await client.transactions(filter: TransactionFilter(category: .some(categoryID)))
    }

    @Test func transactionsEncodesUncategorized() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("uncategorized=true"))
            #expect(!query.contains("category_id"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        _ = try await client.transactions(filter: TransactionFilter(category: .uncategorized))
    }

    @Test func transactionFetchesOneRowByID() async throws {
        let txID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let envelope = """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "account_id": "22222222-2222-2222-2222-222222222222",
              "amount": -1230,
              "effective_amount": -1230,
              "currency": "EUR",
              "booked_at": "2026-08-20T09:30:00+00:00",
              "value_date": null,
              "description": "TEST MERCHANT 01",
              "display_description": null,
              "status": "booked",
              "role": "personal",
              "suggested_category_id": null,
              "confirmed_category_id": null,
              "effective_category_id": null
            }
            """
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/transactions/\(txID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let transaction = try await client.transaction(id: txID)
        #expect(transaction.id == txID)
        #expect(transaction.amount == -1230)
    }

    @Test func transactionThrowsBadStatusOnUnknownID() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown transaction"}"#.utf8))
        }

        await #expect {
            try await client.transaction(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func confirmCategoryPostsTheCategoryIDAsSnakeCaseJSON() async throws {
        let transactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/transactions/\(transactionID.uuidString)/category")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["category_id"] == categoryID.uuidString)
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.confirmCategory(transactionID: transactionID, categoryID: categoryID)
    }

    @Test func confirmCategoryThrowsBadStatusOnUnknownCategory() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown category"}"#.utf8))
        }

        await #expect {
            try await client.confirmCategory(transactionID: UUID(), categoryID: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func clearCategoryIssuesADeleteToTheCategoryEndpoint() async throws {
        let transactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/transactions/\(transactionID.uuidString)/category")
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.clearCategory(transactionID: transactionID)
    }

    /// A representative `GET /categories` envelope: one category.
    private static let categoriesEnvelope = """
        { "categories": [
          { "id": "11111111-1111-1111-1111-111111111111", "name": "Alimentari",
            "parent_id": null, "color": "green", "icon": "groceries",
            "created_at": "2026-08-10T09:30:00+00:00" }
        ] }
        """

    @Test func categoriesDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/categories")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.categoriesEnvelope.utf8))
        }

        let categories = try await client.categories()
        #expect(categories.count == 1)
        #expect(categories[0].name == "Alimentari")
    }

    @Test func seedDefaultCategoriesPostsAndDecodesTheResultingSet() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/categories/defaults")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.categoriesEnvelope.utf8))
        }

        let categories = try await client.seedDefaultCategories()
        #expect(categories.count == 1)
        #expect(categories[0].name == "Alimentari")
    }

    @Test func createCategoryPostsTheNameAndDecodesTheCreatedCategory() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/categories")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["name"] == "Alimentari")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "11111111-1111-1111-1111-111111111111", "name": "Alimentari",
                  "parent_id": null, "color": "slate", "icon": null,
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.createCategory(name: "Alimentari")
        #expect(category.name == "Alimentari")
    }

    @Test func createCategoryWithParentPostsParentIDColorAndIcon() async throws {
        let parentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/categories")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["name"] == "Affitto")
            #expect(body?["parent_id"] == parentID.uuidString)
            #expect(body?["color"] == "indigo")
            #expect(body?["icon"] == "rent")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "11111111-1111-1111-1111-111111111111", "name": "Affitto",
                  "parent_id": "\(parentID.uuidString)", "color": "indigo", "icon": "rent",
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.createCategory(
            name: "Affitto", parentID: parentID, color: .indigo, icon: .rent
        )
        #expect(category.parentID == parentID)
        #expect(category.color == .indigo)
        #expect(category.icon == .rent)
    }

    @Test func createCategoryThrowsBadStatusOnADuplicateName() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "category_name_taken"}"#.utf8))
        }

        await #expect {
            try await client.createCategory(name: "Alimentari")
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    @Test func renameCategoryPostsToTheRenameEndpoint() async throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/categories/\(categoryID.uuidString)/rename")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["name"] == "Spesa")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(categoryID.uuidString)", "name": "Spesa",
                  "parent_id": null, "color": "slate", "icon": null,
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.renameCategory(id: categoryID, name: "Spesa")
        #expect(category.name == "Spesa")
    }

    @Test func setCategoryAppearancePostsColorAndIconAndDecodesThem() async throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/categories/\(categoryID.uuidString)/appearance")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["color"] as? String == "teal")
            #expect(body?["icon"] is NSNull)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(categoryID.uuidString)", "name": "Spesa",
                  "parent_id": null, "color": "teal", "icon": null,
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.setCategoryAppearance(
            id: categoryID, color: .teal, icon: nil
        )
        #expect(category.color == .teal)
        #expect(category.icon == nil)
    }

    @Test func moveCategoryPostsTheNewParentAndDecodesIt() async throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/categories/\(categoryID.uuidString)/move")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["parent_id"] == parentID.uuidString)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(categoryID.uuidString)", "name": "Affitto",
                  "parent_id": "\(parentID.uuidString)", "color": "slate", "icon": null,
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.moveCategory(id: categoryID, parentID: parentID)
        #expect(category.parentID == parentID)
    }

    @Test func moveCategoryToNilParentSendsExplicitNull() async throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["parent_id"] is NSNull)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                { "id": "\(categoryID.uuidString)", "name": "Affitto",
                  "parent_id": null, "color": "slate", "icon": null,
                  "created_at": "2026-08-24T09:30:00+00:00" }
                """
            return (response, Data(envelope.utf8))
        }

        let category = try await client.moveCategory(id: categoryID, parentID: nil)
        #expect(category.parentID == nil)
    }

    @Test func deleteCategoryIssuesADeleteToTheCategoryEndpoint() async throws {
        let categoryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/categories/\(categoryID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteCategory(id: categoryID)
    }

    @Test func deleteCategoryThrowsBadStatusWhenTheCategoryIsInUse() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "category_in_use"}"#.utf8))
        }

        await #expect {
            try await client.deleteCategory(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    /// A representative `GET /rules` envelope: one rule, in evaluation order.
    private static let rulesEnvelope = """
        { "rules": [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "category_id": "22222222-2222-2222-2222-222222222222",
            "match_kind": "contains",
            "pattern": "TEST MERCHANT 01",
            "created_at": "2026-08-24T09:30:00+00:00"
          }
        ] }
        """

    @Test func rulesDecodesEnvelopeInEvaluationOrder() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/rules")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.rulesEnvelope.utf8))
        }

        let rules = try await client.rules()
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "TEST MERCHANT 01")
        #expect(rules[0].matchKind == .contains)
    }

    @Test func rulesDecodesAnEmptyEnvelope() async throws {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{ "rules": [] }"#.utf8))
        }

        let rules = try await client.rules()
        #expect(rules.isEmpty)
    }

    @Test func createRulePostsTheRequestAsSnakeCaseJSON() async throws {
        let categoryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/rules")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["category_id"] == categoryID.uuidString)
            #expect(body?["match_kind"] == "starts_with")
            #expect(body?["pattern"] == "TEST MERCHANT 01")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "category_id": "\(categoryID.uuidString)",
                  "match_kind": "starts_with",
                  "pattern": "TEST MERCHANT 01",
                  "created_at": "2026-08-24T09:30:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let rule = try await client.createRule(
            CreateRuleRequest(categoryID: categoryID, matchKind: .startsWith, pattern: "TEST MERCHANT 01")
        )
        #expect(rule.categoryID == categoryID)
        #expect(rule.matchKind == .startsWith)
    }

    @Test func createRuleThrowsBadStatusOnADuplicate() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "rule_already_exists"}"#.utf8))
        }

        await #expect {
            try await client.createRule(
                CreateRuleRequest(categoryID: UUID(), matchKind: .contains, pattern: "TEST MERCHANT 01")
            )
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    @Test func createRuleThrowsBadStatusOnAnInvalidPattern() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "blank_pattern"}"#.utf8))
        }

        await #expect {
            try await client.createRule(
                CreateRuleRequest(categoryID: UUID(), matchKind: .contains, pattern: "")
            )
        } throws: { error in
            guard case APIError.badStatus(422) = error else { return false }
            return true
        }
    }

    @Test func deleteRuleIssuesADeleteToTheRuleEndpoint() async throws {
        let ruleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/rules/\(ruleID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteRule(id: ruleID)
    }

    @Test func deleteRuleThrowsBadStatusOnUnknownRule() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown rule"}"#.utf8))
        }

        await #expect {
            try await client.deleteRule(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func applyRulesPostsToTheApplyEndpointAndDecodesTheCounts() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/rules/apply")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{ "rules_applied": 4, "matched": 128, "cleared": 401 }"#.utf8))
        }

        let result = try await client.applyRules()
        #expect(result.rulesApplied == 4)
        #expect(result.matched == 128)
        #expect(result.cleared == 401)
    }

    /// A representative `GET /advances` envelope: one advance, no participants.
    private static let advancesEnvelope = """
        { "advances": [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "transaction_id": "22222222-2222-2222-2222-222222222222",
            "own_share": 1800,
            "receivable": 3600,
            "reimbursed": 0,
            "outstanding": 3600,
            "excess": 0,
            "currency": "EUR",
            "status": "open",
            "participants": [],
            "created_at": "2026-08-18T21:40:00+00:00"
          }
        ] }
        """

    @Test func advancesDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/advances")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.advancesEnvelope.utf8))
        }

        let advances = try await client.advances()
        #expect(advances.count == 1)
        #expect(advances[0].ownShare == 1800)
        #expect(advances[0].status == .open)
    }

    @Test func advanceFetchesOneRowByID() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        // `GET /advances/{id}` answers with the bare object, not the
        // `{ "advances": [...] }` envelope `GET /advances` uses.
        let envelope = """
            {
              "id": "\(advanceID.uuidString)",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1800,
              "receivable": 3600,
              "reimbursed": 1800,
              "outstanding": 1800,
              "excess": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            }
            """
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let advance = try await client.advance(id: advanceID)
        #expect(advance.id == advanceID)
        #expect(advance.ownShare == 1800)
        #expect(advance.reimbursed == 1800)
    }

    @Test func createAdvancePostsTheRequestAndDecodesTheCreatedAdvance() async throws {
        let transactionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/advances")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["transaction_id"] as? String == transactionID.uuidString)
            #expect(body?["own_share"] as? Int == 1800)
            // 201 Created, with the created advance in the body.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "transaction_id": "\(transactionID.uuidString)",
                  "own_share": 1800,
                  "receivable": 3600,
                  "reimbursed": 0,
                  "outstanding": 3600,
                  "excess": 0,
                  "currency": "EUR",
                  "status": "open",
                  "participants": [],
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let advance = try await client.createAdvance(
            CreateAdvanceRequest(transactionID: transactionID, ownShare: 1800)
        )
        #expect(advance.transactionID == transactionID)
        #expect(advance.ownShare == 1800)
    }

    @Test func createAdvanceThrowsBadStatusOnInvalidShare() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "share_out_of_range"}"#.utf8))
        }

        await #expect {
            try await client.createAdvance(CreateAdvanceRequest(transactionID: UUID(), ownShare: 999_999))
        } throws: { error in
            guard case APIError.badStatus(422) = error else { return false }
            return true
        }
    }

    @Test func deleteAdvanceIssuesADeleteToTheAdvanceEndpoint() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)")
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteAdvance(id: advanceID)
    }

    @Test func deleteAdvanceThrowsBadStatusOnUnknownAdvance() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown advance"}"#.utf8))
        }

        await #expect {
            try await client.deleteAdvance(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func writeOffAdvancePostsToTheWriteOffEndpointAndDecodesTheUpdatedAdvance() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let envelope = """
            {
              "id": "\(advanceID.uuidString)",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1800,
              "receivable": 3600,
              "reimbursed": 0,
              "outstanding": 0,
              "excess": 0,
              "currency": "EUR",
              "status": "written_off",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            }
            """
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)/write-off")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let advance = try await client.writeOffAdvance(id: advanceID)
        #expect(advance.status == .writtenOff)
    }

    @Test func reopenAdvancePostsToTheReopenEndpointAndDecodesTheUpdatedAdvance() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let envelope = """
            {
              "id": "\(advanceID.uuidString)",
              "transaction_id": "22222222-2222-2222-2222-222222222222",
              "own_share": 1800,
              "receivable": 3600,
              "reimbursed": 0,
              "outstanding": 3600,
              "excess": 0,
              "currency": "EUR",
              "status": "open",
              "participants": [],
              "created_at": "2026-08-18T21:40:00+00:00"
            }
            """
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)/reopen")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let advance = try await client.reopenAdvance(id: advanceID)
        #expect(advance.status == .open)
    }

    @Test func createReimbursementPostsTheRequestAndDecodesTheCreatedReimbursement() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)/reimbursements")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["amount"] as? Int == 1800)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "advance_id": "\(advanceID.uuidString)",
                  "amount": 1800,
                  "currency": "EUR",
                  "transaction_id": null,
                  "note": null,
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let reimbursement = try await client.createReimbursement(
            advanceID: advanceID, CreateReimbursementRequest(amount: 1800)
        )
        #expect(reimbursement.advanceID == advanceID)
        #expect(reimbursement.amount == 1800)
    }

    @Test func createReimbursementThrowsBadStatusOnAWrittenOffAdvance() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "advance_written_off"}"#.utf8))
        }

        await #expect {
            try await client.createReimbursement(advanceID: UUID(), CreateReimbursementRequest(amount: 100))
        } throws: { error in
            guard case APIError.badStatus(422) = error else { return false }
            return true
        }
    }

    @Test func reimbursementsDecodesEnvelope() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let envelope = """
            { "reimbursements": [
              {
                "id": "33333333-3333-3333-3333-333333333333",
                "advance_id": "\(advanceID.uuidString)",
                "amount": 1800,
                "currency": "EUR",
                "transaction_id": null,
                "note": null,
                "created_at": "2026-08-18T21:40:00+00:00"
              }
            ] }
            """
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/advances/\(advanceID.uuidString)/reimbursements")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let reimbursements = try await client.reimbursements(advanceID: advanceID)
        #expect(reimbursements.count == 1)
        #expect(reimbursements[0].amount == 1800)
    }

    @Test func deleteReimbursementIssuesADeleteToTheReimbursementEndpoint() async throws {
        let advanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let reimbursementID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(
                request.url?.path
                    == "/advances/\(advanceID.uuidString)/reimbursements/\(reimbursementID.uuidString)"
            )
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteReimbursement(advanceID: advanceID, id: reimbursementID)
    }

    @Test func deleteReimbursementThrowsBadStatusOnUnknownReimbursement() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown reimbursement"}"#.utf8))
        }

        await #expect {
            try await client.deleteReimbursement(advanceID: UUID(), id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    /// A representative `GET /connections` envelope: one connection, expiring
    /// soon, never synced.
    private static let connectionsEnvelope = """
        { "connections": [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "provider": "enable_banking",
            "institution_name": "Revolut",
            "status": "active",
            "consent_state": "expiring_soon",
            "days_until_expiry": 9,
            "expires_at": "2026-09-01T00:00:00+00:00",
            "created_at": "2026-08-01T09:30:00+00:00",
            "last_synced_at": null,
            "background_sync_enabled": false,
            "sync_budget_remaining": null,
            "next_sync_at": null
          }
        ] }
        """

    @Test func connectionsDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/connections")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.connectionsEnvelope.utf8))
        }

        let connections = try await client.connections()
        #expect(connections.count == 1)
        #expect(connections[0].institutionName == "Revolut")
        #expect(connections[0].status == .active)
        #expect(connections[0].consentState == .expiringSoon)
        #expect(connections[0].daysUntilExpiry == 9)
        #expect(connections[0].lastSyncedAt == nil)
    }

    @Test func connectionsRejectsAnUnknownConsentState() async {
        let unknownStateEnvelope = """
            { "connections": [
              {
                "id": "11111111-1111-1111-1111-111111111111",
                "provider": "enable_banking",
                "institution_name": "Revolut",
                "status": "active",
                "consent_state": "not_a_real_state",
                "days_until_expiry": 9,
                "expires_at": null,
                "created_at": "2026-08-01T09:30:00+00:00",
                "last_synced_at": null,
                "background_sync_enabled": false,
                "sync_budget_remaining": null,
                "next_sync_at": null
              }
            ] }
            """
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(unknownStateEnvelope.utf8))
        }

        await #expect {
            try await client.connections()
        } throws: { error in
            guard case APIError.decoding = error else { return false }
            return true
        }
    }

    @Test func connectionsDecodesAnEmptyEnvelope() async throws {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{ "connections": [] }"#.utf8))
        }

        let connections = try await client.connections()
        #expect(connections.isEmpty)
    }

    private static let institutionsEnvelope = """
        { "institutions": [
          { "name": "TEST BANK 01", "country": "IT" },
          { "name": "TEST BANK 02", "country": "IT" }
        ] }
        """

    @Test func institutionsGetsWithTheCountryQueryItem() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/connections/institutions")
            #expect(request.url?.query == "country=IT")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.institutionsEnvelope.utf8))
        }

        let institutions = try await client.institutions(country: "IT")
        #expect(institutions.count == 2)
        #expect(institutions[0].name == "TEST BANK 01")
        #expect(institutions[0].country == "IT")
    }

    private static let syncEnvelope = """
        { "accounts_synced": 2, "transactions_synced": 5 }
        """

    @Test func syncConnectionPostsToTheSyncEndpoint() async throws {
        let connectionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/connections/\(connectionID.uuidString)/sync")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.syncEnvelope.utf8))
        }

        let result = try await client.syncConnection(connectionID: connectionID)
        #expect(result.accountsSynced == 2)
        #expect(result.transactionsSynced == 5)
    }

    @Test func syncConnectionThrowsBadStatusOnLapsedConsent() async {
        let connectionID = UUID()
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "consent_expired"}"#.utf8))
        }

        await #expect {
            try await client.syncConnection(connectionID: connectionID)
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    private static let startConnectionEnvelope = """
        {
          "connection_id": "11111111-1111-1111-1111-111111111111",
          "authorization_url": "https://sca.example/go"
        }
        """

    @Test func reauthorizeConnectionPostsToTheReauthorizeEndpoint() async throws {
        let connectionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/connections/\(connectionID.uuidString)/reauthorize")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.startConnectionEnvelope.utf8))
        }

        let result = try await client.reauthorizeConnection(connectionID: connectionID)
        #expect(result.connectionID == connectionID)
        #expect(result.authorizationURL == "https://sca.example/go")
    }

    @Test func startConnectionPostsTheInstitutionCountryAndLogoAsSnakeCaseJSON() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/connections")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["institution"] == "TEST BANK 01")
            #expect(body?["country"] == "IT")
            #expect(body?["logo"] == "https://logos.example.test/tb01/")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.startConnectionEnvelope.utf8))
        }

        let result = try await client.startConnection(
            institution: "TEST BANK 01", country: "IT", logo: "https://logos.example.test/tb01/"
        )
        #expect(result.connectionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(result.authorizationURL == "https://sca.example/go")
    }

    @Test func startConnectionOmitsLogoFromThePayloadWhenNil() async throws {
        let client = Self.makeClient { request in
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["institution"] as? String == "TEST BANK 01")
            #expect(body?.keys.contains("logo") == false)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.startConnectionEnvelope.utf8))
        }

        _ = try await client.startConnection(institution: "TEST BANK 01", country: "IT", logo: nil)
    }

    /// A `TransactionResponse` object as embedded in a suggestion's legs.
    private static func transferLeg(id: String, amount: Int) -> String {
        """
        { "id": "\(id)", "account_id": "99999999-9999-9999-9999-999999999999",
          "amount": \(amount), "effective_amount": \(amount), "currency": "EUR",
          "booked_at": "2026-08-20T09:30:00+00:00", "value_date": null,
          "description": "TEST MERCHANT 01", "display_description": null,
          "status": "booked", "role": "personal", "suggested_category_id": null,
          "confirmed_category_id": null, "effective_category_id": null, "event_id": null }
        """
    }

    /// A representative `GET /transfers/suggestions` envelope: one suggestion
    /// with both legs embedded.
    private static let transferSuggestionsEnvelope = """
        { "suggestions": [
          {
            "kind": "two_sided",
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "currency": "EUR",
            "outgoing_amount": -25000,
            "incoming_amount": 25000,
            "amount_delta": 0,
            "day_gap": 0,
            "outgoing": \(Self.transferLeg(id: "11111111-1111-1111-1111-111111111111", amount: -25000)),
            "incoming": \(Self.transferLeg(id: "22222222-2222-2222-2222-222222222222", amount: 25000))
          }
        ] }
        """

    @Test func transferSuggestionsDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/transfers/suggestions")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transferSuggestionsEnvelope.utf8))
        }

        let suggestions = try await client.transferSuggestions()
        #expect(suggestions.count == 1)
        #expect(suggestions[0].outgoingAmount == -25000)
        #expect(suggestions[0].incomingAmount == 25000)
    }

    /// A representative `GET /transfers` envelope: one confirmed transfer.
    private static let transfersEnvelope = """
        { "transfers": [
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "kind": "two_sided",
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "created_at": "2026-08-20T09:30:00+00:00"
          }
        ] }
        """

    @Test func transfersDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.url?.path == "/transfers")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transfersEnvelope.utf8))
        }

        let transfers = try await client.transfers()
        #expect(transfers.count == 1)
        #expect(transfers[0].outgoingTransactionID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    @Test func confirmTransferPostsBothLegsAndDecodesTheCreatedTransfer() async throws {
        let outgoingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let incomingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/transfers/confirm")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["kind"] == "funded_payment")
            #expect(body?["outgoing_transaction_id"] == outgoingID.uuidString)
            #expect(body?["incoming_transaction_id"] == incomingID.uuidString)
            // 201 Created, with the created transfer in the body.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "kind": "funded_payment",
                  "outgoing_transaction_id": "\(outgoingID.uuidString)",
                  "incoming_transaction_id": "\(incomingID.uuidString)",
                  "created_at": "2026-08-20T09:30:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let transfer = try await client.confirmTransfer(
            outgoingID: outgoingID, incomingID: incomingID, kind: .fundedPayment
        )
        #expect(transfer.kind == .fundedPayment)
        #expect(transfer.outgoingTransactionID == outgoingID)
        #expect(transfer.incomingTransactionID == incomingID)
    }

    @Test func confirmTransferThrowsBadStatusWhenAlreadyLinked() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "transaction already in a transfer"}"#.utf8))
        }

        await #expect {
            try await client.confirmTransfer(outgoingID: UUID(), incomingID: UUID(), kind: .twoSided)
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    @Test func rejectTransferPostsBothLegsWithNoResponseBody() async throws {
        let outgoingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let incomingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/transfers/reject")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["outgoing_transaction_id"] == outgoingID.uuidString)
            #expect(body?["incoming_transaction_id"] == incomingID.uuidString)
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.rejectTransfer(outgoingID: outgoingID, incomingID: incomingID)
    }

    @Test func deleteTransferIssuesADeleteToTheTransferEndpoint() async throws {
        let transferID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/transfers/\(transferID.uuidString)")
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteTransfer(id: transferID)
    }

    @Test func deleteTransferThrowsBadStatusOnUnknownTransfer() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown transfer"}"#.utf8))
        }

        await #expect {
            try await client.deleteTransfer(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func eventsDecodesEnvelope() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/events")
            let envelope = """
                { "events": [ {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "TEST TRIP 01",
                  "start_date": "2026-08-01",
                  "end_date": null,
                  "status": "active",
                  "member_count": 1,
                  "total": -5000,
                  "currency": "EUR",
                  "created_at": "2026-08-18T21:40:00+00:00"
                } ] }
                """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let events = try await client.events()
        #expect(events.count == 1)
        #expect(events[0].name == "TEST TRIP 01")
        #expect(events[0].startDate == CalendarDate(year: 2026, month: 8, day: 1))
    }

    @Test func eventFetchesOneRowByID() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/events/\(eventID.uuidString)")
            let envelope = """
                {
                  "id": "\(eventID.uuidString)",
                  "name": "TEST TRIP 01",
                  "start_date": null,
                  "end_date": null,
                  "status": "active",
                  "member_count": 0,
                  "total": 0,
                  "currency": null,
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let event = try await client.event(id: eventID)
        #expect(event.id == eventID)
    }

    @Test func eventTransactionsDecodesEnvelope() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/events/\(eventID.uuidString)/transactions")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{ "transactions": [] }"#.utf8))
        }

        let members = try await client.eventTransactions(id: eventID)
        #expect(members.isEmpty)
    }

    @Test func createEventPostsTheRequestAsSnakeCaseJSON() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/events")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["name"] as? String == "TEST TRIP 01")
            #expect(body?["start_date"] as? String == "2026-08-01")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "name": "TEST TRIP 01",
                  "start_date": "2026-08-01",
                  "end_date": null,
                  "status": "active",
                  "member_count": 0,
                  "total": 0,
                  "currency": null,
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let event = try await client.createEvent(
            CreateEventRequest(name: "TEST TRIP 01", startDate: CalendarDate(year: 2026, month: 8, day: 1))
        )
        #expect(event.name == "TEST TRIP 01")
    }

    @Test func deleteEventIssuesADeleteToTheEventEndpoint() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/events/\(eventID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteEvent(id: eventID)
    }

    @Test func deleteEventThrowsBadStatusOnUnknownEvent() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "unknown event"}"#.utf8))
        }

        await #expect {
            try await client.deleteEvent(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(404) = error else { return false }
            return true
        }
    }

    @Test func closeEventPostsToTheCloseEndpointAndDecodesTheUpdatedEvent() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/events/\(eventID.uuidString)/close")
            let envelope = """
                {
                  "id": "\(eventID.uuidString)",
                  "name": "TEST TRIP 01",
                  "start_date": null,
                  "end_date": null,
                  "status": "closed",
                  "member_count": 0,
                  "total": 0,
                  "currency": null,
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let event = try await client.closeEvent(id: eventID)
        #expect(event.status == .closed)
    }

    @Test func reopenEventPostsToTheReopenEndpointAndDecodesTheUpdatedEvent() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/events/\(eventID.uuidString)/reopen")
            let envelope = """
                {
                  "id": "\(eventID.uuidString)",
                  "name": "TEST TRIP 01",
                  "start_date": null,
                  "end_date": null,
                  "status": "active",
                  "member_count": 0,
                  "total": 0,
                  "currency": null,
                  "created_at": "2026-08-18T21:40:00+00:00"
                }
                """
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(envelope.utf8))
        }

        let event = try await client.reopenEvent(id: eventID)
        #expect(event.status == .active)
    }

    @Test func assignTransactionPostsTheTransactionIDAsSnakeCaseJSON() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let transactionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/events/\(eventID.uuidString)/transactions")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
            #expect(body?["transaction_id"] == transactionID.uuidString)
            // 204 No Content: an empty body must still decode as success.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.assignTransaction(eventID: eventID, transactionID: transactionID)
    }

    @Test func assignTransactionThrowsBadStatusWhenAlreadyInAnotherEvent() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "transaction already in another event"}"#.utf8))
        }

        await #expect {
            try await client.assignTransaction(eventID: UUID(), transactionID: UUID())
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    @Test func unassignTransactionIssuesADeleteToTheMemberEndpoint() async throws {
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let transactionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(
                request.url?.path
                    == "/events/\(eventID.uuidString)/transactions/\(transactionID.uuidString)"
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.unassignTransaction(eventID: eventID, transactionID: transactionID)
    }

    // MARK: Manual accounts and manual transactions (ADR 0020)

    @Test func createManualAccountPostsToAccountsAndDecodesTheManualAccount() async throws {
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/accounts")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["alias"] as? String == "Contanti")
            #expect(body?["kind"] as? String == "cash")
            #expect(body?["currency"] as? String == "EUR")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "55555555-5555-5555-5555-555555555555",
                  "connection_id": null,
                  "source": "manual",
                  "kind": "cash",
                  "currency": "EUR",
                  "name": null,
                  "alias": "Contanti",
                  "display_name": "Contanti",
                  "color": null,
                  "icon": null,
                  "created_at": "2026-08-27T12:00:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let account = try await client.createManualAccount(
            alias: "Contanti", kind: .cash, currency: "EUR", color: nil, icon: nil
        )
        #expect(account.connectionID == nil)
        #expect(account.source == .manual)
        #expect(account.kind == .cash)
    }

    @Test func deleteAccountIssuesADeleteToTheAccountEndpoint() async throws {
        let accountID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/accounts/\(accountID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteAccount(id: accountID)
    }

    @Test func deleteAccountThrowsBadStatusOnANonEmptyOrSyncedAccount() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "account_not_empty"}"#.utf8))
        }

        await #expect {
            try await client.deleteAccount(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }

    /// 2026-08-20T10:00:00Z, built from components so the test never depends
    /// on a hand-computed Unix timestamp.
    private static let valueDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 20; c.hour = 10; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .iso8601).date(from: c)!
    }()

    @Test func createManualTransactionPostsTheRequestAsSnakeCaseJSON() async throws {
        let accountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/transactions")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["account_id"] as? String == accountID.uuidString)
            #expect(body?["amount"] as? Int == -1500)
            #expect(body?["currency"] as? String == "EUR")
            #expect((body?["value_date"] as? String)?.hasPrefix("2026-08-20T10:00:00") == true)
            #expect(body?["description"] as? String == "TEST CASH 01")
            // Omitted, not sent as null, when nil.
            #expect(body?["confirmed_category_id"] == nil)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "99999999-9999-9999-9999-999999999999",
                  "account_id": "\(accountID.uuidString)",
                  "amount": -1500,
                  "effective_amount": -1500,
                  "currency": "EUR",
                  "booked_at": null,
                  "value_date": "2026-08-20T10:00:00+00:00",
                  "description": "TEST CASH 01",
                  "display_description": null,
                  "status": "booked",
                  "role": "personal",
                  "suggested_category_id": null,
                  "confirmed_category_id": null,
                  "effective_category_id": null,
                  "event_id": null
                }
                """
            return (response, Data(envelope.utf8))
        }

        let created = try await client.createManualTransaction(
            CreateManualTransactionRequest(
                accountID: accountID,
                amount: -1500,
                currency: "EUR",
                valueDate: Self.valueDate,
                description: "TEST CASH 01"
            )
        )
        #expect(created.amount == -1500)
        #expect(created.status == .booked)
    }

    @Test func editManualTransactionPostsToTheEditEndpoint() async throws {
        let txID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/transactions/\(txID.uuidString)/edit")
            let bodyData = request.httpBody ?? readAll(request.httpBodyStream)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(body?["amount"] as? Int == -1600)
            #expect(body?["description"] as? String == "TEST CASH 01 v2")
            #expect(body?["account_id"] == nil)  // an edit never moves accounts
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "\(txID.uuidString)",
                  "account_id": "22222222-2222-2222-2222-222222222222",
                  "amount": -1600,
                  "effective_amount": -1600,
                  "currency": "EUR",
                  "booked_at": null,
                  "value_date": "2026-08-21T09:00:00+00:00",
                  "description": "TEST CASH 01 v2",
                  "display_description": null,
                  "status": "booked",
                  "role": "personal",
                  "suggested_category_id": null,
                  "confirmed_category_id": null,
                  "effective_category_id": null,
                  "event_id": null
                }
                """
            return (response, Data(envelope.utf8))
        }

        let edited = try await client.editManualTransaction(
            id: txID,
            EditManualTransactionRequest(
                amount: -1600,
                currency: "EUR",
                valueDate: Self.valueDate,
                description: "TEST CASH 01 v2"
            )
        )
        #expect(edited.amount == -1600)
    }

    @Test func deleteManualTransactionIssuesADeleteToTheTransactionEndpoint() async throws {
        let txID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let client = Self.makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/transactions/\(txID.uuidString)")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        try await client.deleteManualTransaction(id: txID)
    }

    @Test func deleteManualTransactionThrowsBadStatusWhenInUse() async {
        let client = Self.makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"detail": "transaction_in_use"}"#.utf8))
        }

        await #expect {
            try await client.deleteManualTransaction(id: UUID())
        } throws: { error in
            guard case APIError.badStatus(409) = error else { return false }
            return true
        }
    }
}

/// Read every byte of `stream` into `Data`, or empty `Data` if `stream` is `nil`.
///
/// `URLSession` moves a request's `httpBody` into an `httpBodyStream` before
/// handing it to a custom `URLProtocol` in some configurations, so a body
/// assertion needs to fall back to draining the stream when `httpBody` itself
/// is `nil`.
private func readAll(_ stream: InputStream?) -> Data {
    guard let stream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data
}

/// A `URLProtocol` that returns a canned response supplied by a handler.
///
/// The handler is stored in a lock-guarded static because `URLProtocol`
/// instances are created by the loading system, not by the test; the test sets
/// the handler before issuing the request. Serial per test — there is no
/// concurrency between the set and the load here.
final class StubURLProtocol: URLProtocol {
    /// Maps a request to the response and body it should receive.
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    /// Install the handler used for subsequent requests.
    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    private static func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
