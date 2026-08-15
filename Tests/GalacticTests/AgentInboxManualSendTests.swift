import Foundation
import XCTest

@testable import Galactic

/// Sending one chosen message by hand.
///
/// The interesting assertions are all about what this *does not* disturb: the
/// gesture exists for entries automatic delivery has given up on, so it has to
/// reach them without re-admitting them to the loop that gave up.
@MainActor
final class AgentInboxManualSendTests: XCTestCase {

    private func entry(
        _ body: String,
        delivery: AgentInboxEntry.Delivery = .coalescable,
        state: AgentInboxEntry.State = .ready,
        attempts: Int = 0
    ) -> AgentInboxEntry {
        AgentInboxEntry(
            body: body,
            sourceLabel: "test",
            delivery: delivery,
            retry: .retype,
            state: state,
            attempts: attempts)
    }

    // MARK: - Choosing the entry

    /// The difference from `nextUnit`: a reader who pointed at one row gets
    /// that row, not the run it happens to sit in.
    func testItNeverCoalescesEvenWithCoalescableNeighbours() {
        let entries = [
            entry("first"), entry("second"), entry("third"),
        ]

        let unit = AgentInboxSelection.unit(for: entries[1].id, in: entries)

        XCTAssertEqual(unit?.body, "second")
        XCTAssertEqual(unit?.entryIDs, [entries[1].id])
    }

    func testItReachesAPausedEntry() {
        let entries = [entry("held", state: .paused)]

        let unit = AgentInboxSelection.unit(for: entries[0].id, in: entries)

        XCTAssertEqual(unit?.body, "held")
    }

    /// The case the whole feature exists for — `nextUnit` filters this out.
    func testItReachesAStalledEntry() {
        let entries = [entry("given up on", state: .stalled, attempts: 3)]

        XCTAssertNil(
            AgentInboxSelection.nextUnit(from: entries),
            "precondition: automatic delivery will not touch this")
        XCTAssertEqual(
            AgentInboxSelection.unit(for: entries[0].id, in: entries)?.body,
            "given up on")
    }

    func testItAnswersNilForAnEntryThatHasLeft() {
        XCTAssertNil(
            AgentInboxSelection.unit(for: UUID(), in: [entry("present")]))
    }

    // MARK: - Sending it

    /// The chosen entry goes out alone and ahead of its neighbour, and the
    /// ordinary drain picks up behind it.
    ///
    /// Resuming the drain is not a side effect worth avoiding: acceptance is
    /// proof the agent takes prompts, and `canSendNow` had to be true for the
    /// manual send to happen at all — so the rest of the queue was already
    /// eligible and was waiting only for something to wake it.
    func testItSendsTheChosenEntryAloneAndAheadOfTheQueue() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        let first = entry("first")
        let second = entry("second")
        inbox.enqueue(first)
        inbox.enqueue(second)

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: second.id) { reported = $0 }

        XCTAssertEqual(reported, .delivered)
        XCTAssertEqual(
            host.delivered.map(\.body), ["second", "first"],
            "picked first and uncoalesced, then the drain resumes")
        XCTAssertTrue(inbox.isEmpty)
    }

    /// The same gesture with the queue held back: nothing follows, because
    /// nothing else is eligible.
    func testAManualSendDoesNotDragPausedNeighboursOutWithIt() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("held", state: .paused))
        let picked = entry("picked")
        inbox.enqueue(picked)

        consumer.sendNow(id: picked.id) { _ in }

        XCTAssertEqual(host.delivered.map(\.body), ["picked"])
        XCTAssertEqual(inbox.entries.map(\.body), ["held"])
    }

    /// The ceiling bounds the consumer talking itself into another attempt. A
    /// person clicking a button can see the result and is not that loop.
    func testAFailedManualSendDoesNotCountAgainstTheCeiling() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        let held = entry("message", state: .stalled, attempts: 3)
        inbox.enqueue(held)

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: held.id) { reported = $0 }

        XCTAssertEqual(reported, .unconfirmed)
        XCTAssertEqual(inbox.entries.first?.attempts, 3)
    }

    /// A stalled row that fails again is still stalled — it was never re-armed,
    /// so nothing has to put it back.
    func testAFailedManualSendLeavesTheEntryExactlyAsItWas() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message", state: .stalled, attempts: 3))
        let before = inbox.entries

        consumer.sendNow(id: before[0].id) { _ in }

        XCTAssertEqual(inbox.entries, before)
    }

    func testASuccessfulManualSendRetiresAStalledEntry() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        let held = entry("message", state: .stalled, attempts: 3)
        inbox.enqueue(held)

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: held.id) { reported = $0 }

        XCTAssertEqual(reported, .delivered)
        XCTAssertTrue(inbox.isEmpty)
    }

    // MARK: - Refusing

    /// Writing while a blocker stands is the regression that once put three
    /// copies of one comment into a question form. A button does not re-earn it.
    func testItRefusesWhenTheHostSaysNotNow() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.canSendNow = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        let waiting = entry("message")
        inbox.enqueue(waiting)

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: waiting.id) { reported = $0 }

        XCTAssertEqual(reported, .refused)
        XCTAssertTrue(host.delivered.isEmpty, "nothing was written")
        XCTAssertEqual(inbox.entries.count, 1)
    }

    func testItRefusesWhileTheDrainIsAlreadyHoldingAUnit() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        let first = entry("first", delivery: .standalone)
        let second = entry("second", delivery: .standalone)
        inbox.enqueue(first)
        inbox.enqueue(second)

        consumer.wake()
        XCTAssertEqual(host.delivered.count, 1, "precondition: one is out")

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: second.id) { reported = $0 }

        XCTAssertEqual(reported, .refused)
        XCTAssertEqual(
            host.delivered.count, 1,
            "the in-flight record is the only thing stopping a double send")
    }

    func testItRefusesAnEntryThatHasAlreadyLeftTheQueue() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)

        var reported: AgentInboxConsumer.ManualSendOutcome?
        consumer.sendNow(id: UUID()) { reported = $0 }

        XCTAssertEqual(reported, .refused)
        XCTAssertTrue(host.delivered.isEmpty)
    }

    // MARK: - The predicate a control reads

    func testCanSendNowTracksBothHalvesOfTheAnswer() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message", delivery: .standalone))

        XCTAssertTrue(consumer.canSendNow)

        host.canSendNow = false
        XCTAssertFalse(consumer.canSendNow, "the host's half")

        host.canSendNow = true
        consumer.wake()
        XCTAssertFalse(consumer.canSendNow, "the in-flight half")

        host.report(true)
        XCTAssertTrue(consumer.canSendNow)
    }
}
