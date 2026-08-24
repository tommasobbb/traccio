import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for `EventsViewModel` against `FakeAPIClient` — no network stub
/// needed, per `.claude/rules/swift.md`'s "test the seam." Fixtures are
/// synthetic (`.claude/rules/data-safety.md`): invented ids, round amounts,
/// `"TEST TRIP 01"`.
@MainActor
struct EventsViewModelTests {
    private static let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static func makeEvent(
        id: UUID = eventID,
        name: String = "TEST TRIP 01",
        createdAt: Date = Date(timeIntervalSince1970: 1_755_000_000),
        memberCount: Int = 0,
        total: Int = 0,
        currency: String? = nil
    ) -> EventResponse {
        EventResponse(
            id: id, name: name, startDate: nil, endDate: nil, status: .active,
            memberCount: memberCount, total: total, currency: currency, createdAt: createdAt
        )
    }

    @Test func loadSortsEventsNewestFirst() async throws {
        let older = Self.makeEvent(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "OLDER",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = Self.makeEvent(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "NEWER",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let client = FakeAPIClient()
        // The backend returns oldest-first — configure it that way to prove
        // the view model, not the fake, does the sorting.
        await client.setEvents([older, newer])
        let model = EventsViewModel(client: client)

        await model.load()

        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after load()")
            return
        }
        #expect(events.map(\.name) == ["NEWER", "OLDER"])
    }

    @Test func loadFailureIsSurfacedAsFailed() async throws {
        let client = FakeAPIClient()
        await client.setEventsError(FakeAPIError())
        let model = EventsViewModel(client: client)

        await model.load()

        guard case .failed = model.state else {
            Issue.record("expected .failed after an events-list failure")
            return
        }
    }

    @Test func createEventRefetchesRatherThanInsertingLocally() async throws {
        let client = FakeAPIClient()
        await client.setEvents([])
        await client.setCreateEventResult(Self.makeEvent())
        let model = EventsViewModel(client: client)
        await model.load()

        // Reconfigure the fake's list between create and the implicit
        // reload, so a passing test proves the new state came from a
        // refetch, not a local insertion.
        await client.setEvents([Self.makeEvent()])
        await model.createEvent(name: "TEST TRIP 01", startDate: nil, endDate: nil)

        #expect(model.actionFailure == nil)
        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after createEvent()")
            return
        }
        #expect(events.count == 1)
        let requests = await client.createdEventRequests
        #expect(requests.count == 1)
        #expect(requests[0].name == "TEST TRIP 01")
        #expect(requests[0].startDate == nil)
        #expect(requests[0].endDate == nil)
    }

    @Test func createEventFailureSetsActionFailureAndLeavesTheListUntouched() async throws {
        let client = FakeAPIClient()
        await client.setEvents([Self.makeEvent()])
        await client.setCreateEventError(FakeAPIError())
        let model = EventsViewModel(client: client)
        await model.load()

        await model.createEvent(name: "TEST TRIP 02", startDate: nil, endDate: nil)

        #expect(model.actionFailure == .generic)
        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after a failed createEvent()")
            return
        }
        #expect(events.count == 1)
    }

    @Test func replaceUpdatesTheMatchingRowInPlace() async throws {
        let client = FakeAPIClient()
        await client.setEvents([Self.makeEvent(memberCount: 0, total: 0)])
        let model = EventsViewModel(client: client)
        await model.load()

        model.replace(Self.makeEvent(memberCount: 2, total: -5000, currency: "EUR"))

        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after replace(_:)")
            return
        }
        #expect(events.count == 1)
        #expect(events[0].memberCount == 2)
        #expect(events[0].total == -5000)
    }

    @Test func replaceIsANoOpForAnUnknownID() async throws {
        let client = FakeAPIClient()
        await client.setEvents([Self.makeEvent()])
        let model = EventsViewModel(client: client)
        await model.load()

        model.replace(Self.makeEvent(id: UUID(), name: "SOMEONE ELSE'S EVENT"))

        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after replace(_:)")
            return
        }
        #expect(events.count == 1)
        #expect(events[0].name == "TEST TRIP 01")
    }

    @Test func removeDropsTheMatchingRow() async throws {
        let client = FakeAPIClient()
        await client.setEvents([Self.makeEvent()])
        let model = EventsViewModel(client: client)
        await model.load()

        model.remove(id: Self.eventID)

        guard case .loaded(let events) = model.state else {
            Issue.record("expected .loaded after remove(id:)")
            return
        }
        #expect(events.isEmpty)
    }
}
