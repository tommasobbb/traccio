import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `TransfersViewModel` against `FakeAPIClient` — no network stub
/// needed, per `.claude/rules/swift.md`'s "test the seam." Fixtures are
/// synthetic (`.claude/rules/data-safety.md`): invented ids, round amounts,
/// `"TEST MERCHANT 01"`.
@MainActor
struct TransfersViewModelTests {
    private static let outgoingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let incomingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func makeTransaction(id: UUID, amount: Int) -> TransactionResponse {
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
            effectiveCategoryID: nil
        )
    }

    private static func makeSuggestion() -> TransferSuggestionResponse {
        TransferSuggestionResponse(
            outgoingTransactionID: outgoingID,
            incomingTransactionID: incomingID,
            currency: "EUR",
            outgoingAmount: -25000,
            incomingAmount: 25000,
            amountDelta: 0,
            dayGap: 0
        )
    }

    /// Configure a `FakeAPIClient` with one suggestion and both its legs
    /// resolvable — the common setup shared by most cases below.
    private static func makeClientWithOneSuggestion() async -> FakeAPIClient {
        let client = FakeAPIClient()
        await client.setTransferSuggestions([Self.makeSuggestion()])
        await client.setTransaction(Self.makeTransaction(id: outgoingID, amount: -25000), forID: outgoingID)
        await client.setTransaction(Self.makeTransaction(id: incomingID, amount: 25000), forID: incomingID)
        return client
    }

    @Test func loadPairsASuggestionWhoseLegsBothResolve() async throws {
        let client = await Self.makeClientWithOneSuggestion()
        let model = TransfersViewModel(client: client)

        await model.load()

        guard case .loaded(let pairs) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(pairs.count == 1)
        #expect(pairs[0].outgoing.id == Self.outgoingID)
        #expect(pairs[0].incoming.id == Self.incomingID)
    }

    @Test func loadFailureIsSurfacedAsFailed() async throws {
        let client = FakeAPIClient()
        await client.setTransferSuggestionsError(FakeAPIError())
        let model = TransfersViewModel(client: client)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed after a suggestions-list failure")
            return
        }
    }

    @Test func confirmSuccessNotifiesOnUpdateWithBothLegsAndRemovesThePair() async throws {
        let client = await Self.makeClientWithOneSuggestion()
        let confirmedOutgoing = Self.makeTransaction(id: Self.outgoingID, amount: -25000)
        let confirmedIncoming = Self.makeTransaction(id: Self.incomingID, amount: 25000)
        await client.setTransaction(confirmedOutgoing, forID: Self.outgoingID)
        await client.setTransaction(confirmedIncoming, forID: Self.incomingID)
        await client.setConfirmTransferResult(
            TransferResponse(
                id: UUID(), outgoingTransactionID: Self.outgoingID, incomingTransactionID: Self.incomingID,
                createdAt: Date()
            )
        )

        var updatedIDs: [UUID] = []
        let model = TransfersViewModel(client: client, onUpdate: { updatedIDs.append($0.id) })
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.confirm(pair)

        #expect(Set(updatedIDs) == [Self.outgoingID, Self.incomingID])
        #expect(model.actionFailure == nil)
        guard case .loaded(let remaining) = model.state else {
            Issue.record("expected .loaded after confirm()")
            return
        }
        #expect(remaining.isEmpty)
        #expect(
            await client.confirmedTransferPairs == [
                FakeAPIClient.RecordedTransferPair(outgoingID: Self.outgoingID, incomingID: Self.incomingID)
            ]
        )
    }

    @Test func confirmSuccessInvalidatesTheDashboardFreshnessScope() async throws {
        // Confirming zeroes both legs' effectiveAmount — a change GET
        // /dashboard/summary's totals must reflect (`DataFreshness`'s doc
        // comment).
        let client = await Self.makeClientWithOneSuggestion()
        await client.setTransaction(
            Self.makeTransaction(id: Self.outgoingID, amount: -25000), forID: Self.outgoingID
        )
        await client.setTransaction(
            Self.makeTransaction(id: Self.incomingID, amount: 25000), forID: Self.incomingID
        )
        await client.setConfirmTransferResult(
            TransferResponse(
                id: UUID(), outgoingTransactionID: Self.outgoingID, incomingTransactionID: Self.incomingID,
                createdAt: Date()
            )
        )
        let freshness = DataFreshness()

        let model = TransfersViewModel(
            client: client, onDashboardStale: { freshness.markStale([.dashboard]) }
        )
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.confirm(pair)

        #expect(freshness.token(for: .dashboard) == 1)
    }

    @Test func confirmFailureNeverInvalidatesDashboardFreshness() async throws {
        let client = await Self.makeClientWithOneSuggestion()
        await client.setConfirmTransferError(FakeAPIError())
        let freshness = DataFreshness()

        let model = TransfersViewModel(
            client: client, onDashboardStale: { freshness.markStale([.dashboard]) }
        )
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.confirm(pair)

        #expect(model.actionFailure == .generic)
        #expect(freshness.token(for: .dashboard) == 0)
    }

    @Test func rejectNeverInvalidatesDashboardFreshness() async throws {
        // A reject only records a dismissal — no role changes, so nothing
        // on the dashboard changes either.
        let client = await Self.makeClientWithOneSuggestion()
        let freshness = DataFreshness()

        let model = TransfersViewModel(
            client: client, onDashboardStale: { freshness.markStale([.dashboard]) }
        )
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.reject(pair)

        #expect(freshness.token(for: .dashboard) == 0)
    }

    @Test func confirmFailureKeepsThePairAndSetsActionFailure() async throws {
        let client = await Self.makeClientWithOneSuggestion()
        await client.setConfirmTransferError(FakeAPIError())

        var updateCallCount = 0
        let model = TransfersViewModel(client: client, onUpdate: { _ in updateCallCount += 1 })
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.confirm(pair)

        #expect(model.actionFailure == .generic)
        #expect(updateCallCount == 0)
        guard case .loaded(let remaining) = model.state else {
            Issue.record("expected .loaded after a failed confirm()")
            return
        }
        #expect(remaining.count == 1)
    }

    @Test func rejectSuccessRemovesThePairWithoutCallingOnUpdate() async throws {
        let client = await Self.makeClientWithOneSuggestion()

        var updateCallCount = 0
        let model = TransfersViewModel(client: client, onUpdate: { _ in updateCallCount += 1 })
        await model.load()
        guard case .loaded(let pairs) = model.state, let pair = pairs.first else {
            Issue.record("expected one loaded pair")
            return
        }

        await model.reject(pair)

        #expect(updateCallCount == 0)
        guard case .loaded(let remaining) = model.state else {
            Issue.record("expected .loaded after reject()")
            return
        }
        #expect(remaining.isEmpty)
        #expect(
            await client.rejectedTransferPairs == [
                FakeAPIClient.RecordedTransferPair(outgoingID: Self.outgoingID, incomingID: Self.incomingID)
            ]
        )
    }

    @Test func aSuggestionWhoseLegDoesNotResolveIsDropped() async throws {
        let client = FakeAPIClient()
        await client.setTransferSuggestions([Self.makeSuggestion()])
        // Only the outgoing leg resolves; the incoming leg is left unconfigured.
        await client.setTransaction(Self.makeTransaction(id: Self.outgoingID, amount: -25000), forID: Self.outgoingID)

        let model = TransfersViewModel(client: client)
        await model.load()

        guard case .loaded(let pairs) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(pairs.isEmpty)
    }
}
