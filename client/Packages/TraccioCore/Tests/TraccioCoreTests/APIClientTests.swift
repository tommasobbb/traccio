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
