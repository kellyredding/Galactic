import Foundation
import XCTest

@testable import Galactic

/// The queue holds order and attempt history, and nothing else.
@MainActor
final class AgentInboxTests: XCTestCase {

    private func entry(
        _ body: String,
        id: UUID = UUID(),
        delivery: AgentInboxEntry.Delivery = .coalescable,
        state: AgentInboxEntry.State = .ready
    ) -> AgentInboxEntry {
        AgentInboxEntry(
            id: id,
            body: body,
            sourceLabel: "test",
            delivery: delivery,
            retry: .retype,
            state: state)
    }

    // MARK: - Enqueue

    func testEnqueueAppendsInOrder() {
        let inbox = AgentInbox()

        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))

        XCTAssertEqual(inbox.entries.map(\.body), ["first", "second"])
    }

    func testAFreshInboxIsEmptyAndHasNoWork() {
        let inbox = AgentInbox()

        XCTAssertTrue(inbox.isEmpty)
        XCTAssertFalse(inbox.hasSendableWork)
    }

    /// The distinction a host's indicator depends on. A queue holding only held
    /// rows is not empty — it just has nothing a consumer could act on, and a
    /// host that conflated the two would wake a consumer forever.
    func testAQueueOfHeldRowsIsNotEmptyButHasNoWork() {
        let inbox = AgentInbox()

        inbox.enqueue(entry("paused", state: .paused))
        inbox.enqueue(entry("stalled", state: .stalled))

        XCTAssertFalse(inbox.isEmpty)
        XCTAssertFalse(inbox.hasSendableWork)
    }

    // MARK: - Completion

    func testCompletionRetiresExactlyTheUnitsEntries() throws {
        let inbox = AgentInbox()
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))
        inbox.enqueue(entry("/clear", delivery: .standalone))

        inbox.complete(try XCTUnwrap(inbox.nextUnit()))

        XCTAssertEqual(inbox.entries.map(\.body), ["/clear"])
    }

    /// Matched by id, not by position. A message enqueued while a unit was in
    /// flight shifts every index — retiring "the first two" would then retire
    /// something that was never sent.
    func testCompletionIsUnaffectedByAReorderMidFlight() throws {
        let inbox = AgentInbox()
        let first = UUID()
        let second = UUID()
        inbox.enqueue(entry("first", id: first))
        inbox.enqueue(entry("second", id: second))

        let unit = try XCTUnwrap(inbox.nextUnit())
        inbox.enqueue(entry("arrived late"))
        inbox.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        inbox.complete(unit)

        XCTAssertEqual(inbox.entries.map(\.body), ["arrived late"])
    }

    // MARK: - Attempt accounting

    func testAFailedAttemptKeepsTheEntryAndCountsIt() throws {
        let inbox = AgentInbox()
        inbox.enqueue(entry("message"))
        let unit = try XCTUnwrap(inbox.nextUnit())

        inbox.recordAttemptFailure(unit, ceiling: 3)

        XCTAssertEqual(inbox.entries.count, 1)
        XCTAssertEqual(inbox.entries.first?.attempts, 1)
        XCTAssertEqual(
            inbox.entries.first?.state, .ready,
            "one failure is a hiccup, not a stall")
    }

    func testReachingTheCeilingStalls() throws {
        let inbox = AgentInbox()
        inbox.enqueue(entry("message"))

        for _ in 0..<3 {
            let unit = try XCTUnwrap(inbox.nextUnit())
            inbox.recordAttemptFailure(unit, ceiling: 3)
        }

        XCTAssertEqual(inbox.entries.first?.state, .stalled)
        XCTAssertNil(
            inbox.nextUnit(),
            "a stalled entry is not handed out again")
    }

    /// Every entry in a coalesced unit wears the failure, since the whole
    /// submit is what went unconfirmed.
    func testAFailedRunCountsAgainstEveryEntryInIt() throws {
        let inbox = AgentInbox()
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))
        let unit = try XCTUnwrap(inbox.nextUnit())

        inbox.recordAttemptFailure(unit, ceiling: 3)

        XCTAssertEqual(inbox.entries.map(\.attempts), [1, 1])
    }

    // MARK: - The reader's edits

    func testMoveReordersWhatGoesNext() throws {
        let inbox = AgentInbox()
        inbox.enqueue(entry("first", delivery: .standalone))
        inbox.enqueue(entry("second", delivery: .standalone))

        inbox.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(try XCTUnwrap(inbox.nextUnit()).body, "second")
    }

    func testPausingRemovesAnEntryFromSelection() throws {
        let inbox = AgentInbox()
        let held = UUID()
        inbox.enqueue(entry("held", id: held, delivery: .standalone))
        inbox.enqueue(entry("second", delivery: .standalone))

        inbox.setState(.paused, for: held)

        XCTAssertEqual(try XCTUnwrap(inbox.nextUnit()).body, "second")
    }

    /// The stall is the record of those attempts, so discharging it clears
    /// them. Otherwise the reader's retry would re-stall after one failure,
    /// which makes the gesture look broken.
    func testReturningAStalledEntryToReadyClearsItsAttempts() throws {
        let inbox = AgentInbox()
        let id = UUID()
        inbox.enqueue(entry("message", id: id))
        for _ in 0..<3 {
            let unit = try XCTUnwrap(inbox.nextUnit())
            inbox.recordAttemptFailure(unit, ceiling: 3)
        }

        inbox.setState(.ready, for: id)

        XCTAssertEqual(inbox.entries.first?.attempts, 0)
        XCTAssertNotNil(inbox.nextUnit(), "it is handed out again")
    }

    /// Only a stall discharges. Un-pausing an entry that failed twice before it
    /// was held must not hand it a fresh ceiling — nothing about pausing
    /// answers the question those failures raised.
    func testUnpausingDoesNotClearAttempts() throws {
        let inbox = AgentInbox()
        let id = UUID()
        inbox.enqueue(entry("message", id: id))
        let unit = try XCTUnwrap(inbox.nextUnit())
        inbox.recordAttemptFailure(unit, ceiling: 3)

        inbox.setState(.paused, for: id)
        inbox.setState(.ready, for: id)

        XCTAssertEqual(inbox.entries.first?.attempts, 1)
    }

    func testSettingStateOnAnUnknownEntryDoesNothing() {
        let inbox = AgentInbox()
        inbox.enqueue(entry("message"))

        inbox.setState(.paused, for: UUID())

        XCTAssertEqual(inbox.entries.first?.state, .ready)
    }

    func testRemoveAndRemoveAll() {
        let inbox = AgentInbox()
        let id = UUID()
        inbox.enqueue(entry("first", id: id))
        inbox.enqueue(entry("second"))

        inbox.remove(id: id)
        XCTAssertEqual(inbox.entries.map(\.body), ["second"])

        inbox.removeAll()
        XCTAssertTrue(inbox.isEmpty)
    }
}
