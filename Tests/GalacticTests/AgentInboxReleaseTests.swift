import Foundation
import XCTest

@testable import Galactic

/// Releasing a block the host believes is a lost readiness signal, from the
/// inbox, so a queue held by a signal that never came can be let go.
@MainActor
final class AgentInboxReleaseTests: XCTestCase {

    private func entry(_ body: String) -> AgentInboxEntry {
        AgentInboxEntry(
            body: body,
            sourceLabel: "test",
            delivery: .standalone,
            retry: .resubmit)
    }

    func testAHostThatSaysNothingCannotBeReleased() {
        final class Holder: AgentInboxHost {
            var canSendNow: Bool { false }
            func deliver(_ unit: AgentInboxUnit, accepted: @escaping (Bool) -> Void) {
                accepted(true)
            }
        }
        let host = Holder()
        let consumer = AgentInboxConsumer(inbox: AgentInbox(), host: host)

        XCTAssertFalse(consumer.canReleaseBlock)
        var answer: Bool?
        consumer.releaseBlock(force: true) { answer = $0 }
        XCTAssertEqual(answer, false)
    }

    func testABlockOnlyTimeEndsIsNotOfferedOrAsked() {
        let host = StubAgentInboxHost()
        host.canSendNow = false
        let consumer = AgentInboxConsumer(inbox: AgentInbox(), host: host)

        XCTAssertFalse(consumer.canReleaseBlock)
        var answer: Bool?
        consumer.releaseBlock(force: true) { answer = $0 }

        XCTAssertEqual(answer, false)
        XCTAssertTrue(host.releaseRequests.isEmpty, "the host was not asked")
    }

    func testAReleaseTheHostConfirmsSendsWhatIsWaiting() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.canSendNow = false
        host.canReleaseBlock = true
        host.releasesUnforced = true
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("waiting"))

        var answer: Bool?
        consumer.releaseBlock(force: false) { answer = $0 }

        XCTAssertEqual(answer, true)
        XCTAssertEqual(host.releaseRequests, [false])
        XCTAssertEqual(host.delivered.map(\.body), ["waiting"])
        XCTAssertTrue(inbox.isEmpty)
    }

    func testAnUnconfirmedReleaseSendsNothing() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.canSendNow = false
        host.canReleaseBlock = true
        host.releasesUnforced = false
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("waiting"))

        var answer: Bool?
        consumer.releaseBlock(force: false) { answer = $0 }

        XCTAssertEqual(answer, false)
        XCTAssertTrue(host.delivered.isEmpty)
        XCTAssertEqual(inbox.entries.count, 1)
    }

    func testAForcedReleaseIsPassedThroughAsForced() {
        let inbox = AgentInbox()
        let host = StubAgentInboxHost()
        host.canSendNow = false
        host.canReleaseBlock = true
        host.autoReport = true
        let consumer = AgentInboxConsumer(inbox: inbox, host: host)
        inbox.enqueue(entry("waiting"))

        consumer.releaseBlock(force: true) { _ in }

        XCTAssertEqual(host.releaseRequests, [true])
        XCTAssertEqual(host.delivered.map(\.body), ["waiting"])
    }
}
