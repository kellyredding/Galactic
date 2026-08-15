import Foundation
import XCTest

@testable import Galactic

/// Order is intent, prose travels together, commands travel alone, and a row
/// the reader took out of play does not take the rows behind it out too.
final class AgentInboxSelectionTests: XCTestCase {

    private func entry(
        _ body: String,
        id: UUID = UUID(),
        delivery: AgentInboxEntry.Delivery = .coalescable,
        retry: SubmitRetryPolicy = .retype,
        state: AgentInboxEntry.State = .ready
    ) -> AgentInboxEntry {
        AgentInboxEntry(
            id: id,
            body: body,
            sourceLabel: "test",
            delivery: delivery,
            retry: retry,
            state: state)
    }

    private let separator = AgentInboxSelection.separator

    // MARK: - Nothing to send

    func testAnEmptyQueueOffersNoUnit() {
        XCTAssertNil(AgentInboxSelection.nextUnit(from: []))
    }

    /// Distinct from empty in the queue and identical here: a consumer asking
    /// for work gets the same answer either way, which is what lets it treat
    /// "nothing to do" as one case.
    func testAllPausedOffersNoUnit() {
        let entries = [
            entry("first", state: .paused),
            entry("second", state: .paused),
        ]

        XCTAssertNil(AgentInboxSelection.nextUnit(from: entries))
    }

    // MARK: - Coalescing

    func testASingleCoalescableTravelsAlone() {
        let id = UUID()

        let unit = AgentInboxSelection.nextUnit(from: [entry("only", id: id)])

        XCTAssertEqual(unit?.entryIDs, [id])
        XCTAssertEqual(unit?.body, "only")
    }

    /// The behaviour the reader actually sees: two comments typed during one
    /// turn arrive as one prompt, in the order they were written, rather than
    /// as two prompts a turn apart.
    func testAContiguousRunTravelsAsOneSubmit() {
        let first = UUID()
        let second = UUID()
        let entries = [
            entry("first", id: first),
            entry("second", id: second),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [first, second])
        XCTAssertEqual(unit?.body, "first\(separator)second")
    }

    // MARK: - Standalone

    /// A slash command at the head goes by itself even though prose is queued
    /// behind it. The agent reads one command per prompt; a second body riding
    /// behind a separator would be read as argument text.
    func testAStandaloneHeadTravelsWithoutTheProseBehindIt() {
        let command = UUID()
        let entries = [
            entry("/clear", id: command, delivery: .standalone),
            entry("prose"),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [command])
        XCTAssertEqual(unit?.body, "/clear")
    }

    /// And mid-queue it stops the run rather than joining it — the prose ahead
    /// of it goes now, the command goes next.
    func testAStandaloneMidQueueEndsTheRun() {
        let first = UUID()
        let second = UUID()
        let entries = [
            entry("first", id: first),
            entry("second", id: second),
            entry("/clear", delivery: .standalone),
            entry("after"),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [first, second])
        XCTAssertEqual(unit?.body, "first\(separator)second")
    }

    // MARK: - Held rows are passengers, not walls

    /// Pausing one message means "let everything else go past me". If a paused
    /// row broke the run, pausing the second of three would quietly also defer
    /// the third, which is not the gesture the reader made.
    func testAPausedEntryIsSkippedWithoutBreakingTheRun() {
        let first = UUID()
        let third = UUID()
        let entries = [
            entry("first", id: first),
            entry("second", state: .paused),
            entry("third", id: third),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [first, third])
        XCTAssertEqual(
            unit?.body, "first\(separator)third",
            "the paused body must not appear in the submit")
    }

    /// The sharper version: a paused *standalone* would be a barrier if the
    /// filter ran second, so this pins the ordering of the two steps.
    func testAPausedStandaloneIsNotABarrier() {
        let first = UUID()
        let third = UUID()
        let entries = [
            entry("first", id: first),
            entry("/clear", delivery: .standalone, state: .paused),
            entry("third", id: third),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [first, third])
    }

    /// Stalled rows behave like paused ones, for a sharper reason: the failure
    /// that stalls an entry is a missed acceptance *report*, so the agent may
    /// already be holding it. Blocking the queue behind one would strand it on
    /// a message that probably arrived.
    func testAStalledEntryIsSkippedWithoutBreakingTheRun() {
        let first = UUID()
        let third = UUID()
        let entries = [
            entry("first", id: first),
            entry("second", state: .stalled),
            entry("third", id: third),
        ]

        let unit = AgentInboxSelection.nextUnit(from: entries)

        XCTAssertEqual(unit?.entryIDs, [first, third])
    }

    /// A stalled head must not stop the queue either — it is left visible, and
    /// everything behind it carries on.
    func testAStalledHeadDoesNotStopTheQueue() {
        let second = UUID()
        let entries = [
            entry("stuck", state: .stalled),
            entry("second", id: second),
        ]

        XCTAssertEqual(
            AgentInboxSelection.nextUnit(from: entries)?.entryIDs, [second])
    }

    // MARK: - Retry across a run

    /// The conservative policy wins, because the two failures are not
    /// symmetric: retyping costs the agent a duplicate of something it may
    /// already hold, and declining to retype costs a message that may only be
    /// late.
    func testAMixedRunResolvesToTheConservativePolicy() {
        let entries = [
            entry("bounded", retry: .retype),
            entry("unbounded", retry: .reportOnly),
        ]

        XCTAssertEqual(
            AgentInboxSelection.nextUnit(from: entries)?.retry, .reportOnly)
    }

    func testARunThatAgreesKeepsItsPolicy() {
        let entries = [
            entry("first", retry: .retype),
            entry("second", retry: .retype),
        ]

        XCTAssertEqual(
            AgentInboxSelection.nextUnit(from: entries)?.retry, .retype)
    }

    /// A standalone carries its own policy rather than inheriting a run's,
    /// since it never joins one.
    func testAStandaloneCarriesItsOwnPolicy() {
        let entries = [
            entry("/clear", delivery: .standalone, retry: .retype),
            entry("prose", retry: .reportOnly),
        ]

        XCTAssertEqual(
            AgentInboxSelection.nextUnit(from: entries)?.retry, .retype)
    }

    /// A held row's policy must not leak into the unit it was skipped out of.
    func testAPausedEntrysPolicyDoesNotAffectTheRun() {
        let entries = [
            entry("first", retry: .retype),
            entry("held", retry: .reportOnly, state: .paused),
            entry("third", retry: .retype),
        ]

        XCTAssertEqual(
            AgentInboxSelection.nextUnit(from: entries)?.retry, .retype)
    }

    // MARK: - The separator

    /// Markdown, because both composing surfaces and the agent reading them
    /// already speak it — the rule renders as a division rather than arriving
    /// as literal punctuation.
    func testTheSeparatorIsAMarkdownRuleOnItsOwnLine() {
        XCTAssertEqual(AgentInboxSelection.separator, "\n\n---\n\n")
    }
}
