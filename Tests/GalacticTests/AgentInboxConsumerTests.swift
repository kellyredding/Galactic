import Foundation
import XCTest

@testable import Galactic

/// The consumer's whole job is knowing when *not* to send, so most of this
/// asserts refusals.
@MainActor
final class AgentInboxConsumerTests: XCTestCase {

    private func entry(
        _ body: String,
        delivery: AgentInboxEntry.Delivery = .standalone
    ) -> AgentInboxEntry {
        AgentInboxEntry(
            body: body,
            sourceLabel: "test",
            delivery: delivery,
            retry: .retype)
    }

    // MARK: - Sending

    func testItDrainsWhenTheHostPermits() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message"))

        consumer.wake()

        XCTAssertEqual(host.delivered.map(\.body), ["message"])
        XCTAssertTrue(inbox.isEmpty, "an accepted unit leaves the queue")
    }

    /// The drain loop. Several standalone commands go one per wake until the
    /// queue is empty, rather than each waiting on an unrelated signal.
    func testItDrainsRepeatedlyUntilEmpty() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))
        inbox.enqueue(entry("third"))

        consumer.wake()

        XCTAssertEqual(
            host.delivered.map(\.body), ["first", "second", "third"])
        XCTAssertTrue(inbox.isEmpty)
    }

    func testAcceptanceRetiresEveryEntryInACoalescedUnit() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("first", delivery: .coalescable))
        inbox.enqueue(entry("second", delivery: .coalescable))

        consumer.wake()

        XCTAssertEqual(host.delivered.count, 1, "they travelled together")
        XCTAssertTrue(inbox.isEmpty)
    }

    // MARK: - Refusing

    func testItDeclinesWhenTheHostSaysNotNow() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.canSendNow = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message"))

        consumer.wake()

        XCTAssertTrue(host.delivered.isEmpty)
        XCTAssertEqual(
            inbox.entries.first?.attempts, 0,
            "declining to send is not a failed attempt")
    }

    /// Waking with nothing to do must not reach the host at all — a queue of
    /// held rows would otherwise spend a delivery on nothing.
    func testItDoesNothingWhenThereIsNoWork() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)

        consumer.wake()

        XCTAssertTrue(host.delivered.isEmpty)
    }

    /// The structural gate: no live session means no host means nothing drains.
    /// Asserted by letting the host go and waking anyway.
    func testAVanishedHostStrandsNothingAndSendsNothing() {
        let inbox = AgentInbox()
        var host: StubAgentInboxHost? = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host!)
        inbox.enqueue(entry("message"))

        host = nil
        consumer.wake()

        XCTAssertEqual(
            inbox.entries.count, 1,
            "the message waits rather than being consumed by nobody")
    }

    // MARK: - Overlap

    /// Two wakes in the same frame must not deliver the same message twice.
    /// The host here holds its delivery open, which is exactly the window a
    /// real one occupies while it waits for an acceptance report.
    func testItNeverOverlapsDeliveries() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))

        consumer.wake()
        consumer.wake()
        consumer.wake()

        XCTAssertEqual(host.delivered.count, 1)
        XCTAssertTrue(consumer.isDelivering)
    }

    func testTheNextUnitGoesOnceTheFirstReports() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))

        consumer.wake()
        host.report(true)

        XCTAssertEqual(host.delivered.map(\.body), ["first", "second"])
        XCTAssertTrue(
            consumer.isDelivering,
            "reporting the first hands the second straight out — the loop does "
                + "not wait for another wake")
        XCTAssertEqual(inbox.entries.map(\.body), ["second"])
    }

    /// A doubled callback is a doubled message, so the second report is
    /// discarded rather than trusted.
    func testASecondReportFromTheHostIsIgnored() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("first"))
        inbox.enqueue(entry("second"))

        consumer.wake()
        host.reportTwice(true)

        XCTAssertEqual(
            host.delivered.map(\.body), ["first", "second"],
            "the doubled report must not push a third delivery")
    }

    // MARK: - Failure

    func testAFailedAttemptKeepsTheEntryAndCountsIt() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message"))

        consumer.wake()
        host.report(false)

        XCTAssertEqual(inbox.entries.count, 1)
        XCTAssertEqual(inbox.entries.first?.attempts, 1)
    }

    /// A failure retries, because the blocker it answers is usually transient.
    ///
    /// The case that pays for this is an aborted turn: the agent stops being
    /// readable for as long as it takes to unwind, a write inside that window
    /// is swallowed whole, and the same write lands seconds later. Refusing to
    /// retry leaves the message beside an idle agent until the reader happens
    /// to start another turn.
    ///
    /// Consecutive attempts are spaced by the harness's verification bound —
    /// a failure is not reported until it expires — so there is no interval in
    /// the consumer to get wrong.
    func testAFailedAttemptIsTriedAgain() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message"))

        consumer.wake()

        XCTAssertGreaterThan(host.delivered.count, 1, "it tried again")
    }

    /// **The regression that mattered.** Retrying is bounded, and the bound is
    /// what keeps a persistent blocker from being written into forever.
    ///
    /// An earlier version retried without a ceiling reachable in practice and
    /// put three copies of one comment into an open question form. The ceiling
    /// is what turns "it kept trying" into "it stopped and said so".
    func testItStopsAtTheAttemptCeiling() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("message"))

        consumer.wake()

        XCTAssertEqual(
            host.delivered.count, AgentInboxConsumer.attemptCeiling,
            "tried to the ceiling and no further")
        XCTAssertEqual(inbox.entries.first?.state, .stalled)
        XCTAssertFalse(consumer.isDelivering)

        consumer.wake()

        XCTAssertEqual(
            host.delivered.count, AgentInboxConsumer.attemptCeiling,
            "and a later wake does not restart it")
    }

    /// A stalled entry must not block the queue behind it — the failure that
    /// stalls one is a missed report, so the agent may already have it.
    func testAStalledEntryDoesNotBlockWhatFollows() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.autoReport = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("stalls"))
        consumer.wake()

        host.autoReport = true
        inbox.enqueue(entry("later"))
        consumer.wake()

        XCTAssertEqual(host.delivered.last?.body, "later")
        XCTAssertEqual(
            inbox.entries.map(\.body), ["stalls"],
            "the stalled row stays visible, the new one went")
    }
}
