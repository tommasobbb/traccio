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
              "kind": "current",
              "currency": "EUR",
              "name": "Test Current",
              "created_at": "2026-08-10T09:30:00.123456+00:00"
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "connection_id": "22222222-2222-2222-2222-222222222222",
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
        handler: @escaping StubURLProtocol.Handler
    ) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.setHandler(handler)
        return APIClient(baseURL: URL(string: "http://localhost:8000")!, session: session)
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
          { "currency": "EUR", "spending": 124050, "income": 210000, "net": 85950, "transaction_count": 42 }
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

        let transactions = try await client.transactions(accountID: accountID, limit: 25, offset: 50)
        #expect(transactions.count == 1)
        #expect(transactions[0].amount == -1230)
    }

    @Test func transactionsOmitsAccountIDWhenNil() async throws {
        let client = Self.makeClient { request in
            let query = request.url?.query ?? ""
            #expect(!query.contains("account_id"))
            #expect(query.contains("limit=50"))
            #expect(query.contains("offset=0"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(Self.transactionsEnvelope.utf8))
        }

        _ = try await client.transactions()
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
          { "id": "11111111-1111-1111-1111-111111111111", "name": "Alimentari", "created_at": "2026-08-10T09:30:00+00:00" }
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
            "last_synced_at": null
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
                "last_synced_at": null
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

    /// A representative `GET /transfers/suggestions` envelope: one suggestion.
    private static let transferSuggestionsEnvelope = """
        { "suggestions": [
          {
            "outgoing_transaction_id": "11111111-1111-1111-1111-111111111111",
            "incoming_transaction_id": "22222222-2222-2222-2222-222222222222",
            "currency": "EUR",
            "outgoing_amount": -25000,
            "incoming_amount": 25000,
            "amount_delta": 0,
            "day_gap": 0
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
            #expect(body?["outgoing_transaction_id"] == outgoingID.uuidString)
            #expect(body?["incoming_transaction_id"] == incomingID.uuidString)
            // 201 Created, with the created transfer in the body.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            )!
            let envelope = """
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "outgoing_transaction_id": "\(outgoingID.uuidString)",
                  "incoming_transaction_id": "\(incomingID.uuidString)",
                  "created_at": "2026-08-20T09:30:00+00:00"
                }
                """
            return (response, Data(envelope.utf8))
        }

        let transfer = try await client.confirmTransfer(outgoingID: outgoingID, incomingID: incomingID)
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
            try await client.confirmTransfer(outgoingID: UUID(), incomingID: UUID())
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
