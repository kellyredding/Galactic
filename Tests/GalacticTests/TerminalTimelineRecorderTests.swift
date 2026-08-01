import XCTest
@testable import Galactic

/// The recorder seam, and the two guards that used to be every caller's job.
///
/// The behaviour worth pinning is what happens when there is *nothing* to record
/// to. An app without a timeline supplies no recorder, and every emission has to
/// become a no-op that also does not pay to assemble its payload — those
/// payloads expand note bodies. A seam that only works for the app that wrote it
/// is the failure mode this whole exercise is trying to avoid.
final class TerminalTimelineRecorderTests: XCTestCase {

    // MARK: - The opt-out

    func testNoRecorderRecordsNothing() {
        let recorder: TerminalTimelineRecorder? = nil

        recorder.record(sessionID: 42) { id, _ in
            TerminalTimelineEvent(
                sessionID: id, type: "scrollback:entered",
                paneKind: .session, source: "test"
            )
        }
        // Nothing to assert against beyond not trapping — the point is that an
        // app with no timeline can call this freely.
    }

    /// The payload is not free to build, so a nil recorder must not pay for one.
    func testNoRecorderDoesNotBuildTheEvent() {
        let recorder: TerminalTimelineRecorder? = nil
        var built = 0

        recorder.record(sessionID: 42) { id, _ in
            built += 1
            return TerminalTimelineEvent(
                sessionID: id, type: "scrollback:exited",
                paneKind: .shell, source: "test"
            )
        }

        XCTAssertEqual(
            built, 0,
            "these payloads expand note bodies; assembling one for nowhere is "
                + "work thrown away on every scrollback exit"
        )
    }

    /// A pane with no ledger identity cannot be attributed, so it records
    /// nothing — and again does not pay to find that out.
    func testNoSessionRecordsNothingAndBuildsNothing() {
        var recorded: [TerminalTimelineEvent] = []
        let recorder: TerminalTimelineRecorder? = TerminalTimelineRecorder(
            terminalSource: "views/terminal",
            scrollbackSource: "views/scrollback"
        ) {
            recorded.append($0)
        }
        var built = 0

        recorder.record(sessionID: nil) { id, _ in
            built += 1
            return TerminalTimelineEvent(
                sessionID: id, type: "scrollback:entered",
                paneKind: .session, source: "test"
            )
        }

        XCTAssertEqual(built, 0)
        XCTAssertTrue(recorded.isEmpty)
    }

    // MARK: - Recording

    func testAnEventReachesTheRecorderWithItsSession() {
        var recorded: [TerminalTimelineEvent] = []
        let recorder: TerminalTimelineRecorder? = TerminalTimelineRecorder(
            terminalSource: "views/terminal",
            scrollbackSource: "views/scrollback"
        ) {
            recorded.append($0)
        }

        recorder.record(sessionID: 7) { id, _ in
            TerminalTimelineEvent(
                sessionID: id,
                type: "scrollback:entered",
                paneKind: .session,
                source: "views/terminal",
                durationIdentifier: "scrollback--abc"
            )
        }

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.sessionID, 7)
        XCTAssertEqual(recorded.first?.type, "scrollback:entered")
        XCTAssertEqual(
            recorded.first?.durationIdentifier, "scrollback--abc"
        )
    }

    // MARK: - The pane key

    /// Every emitter was writing this into the detail by hand, and one that
    /// forgot produced an event nothing could attribute to a pane.
    func testThePaneIsMergedIntoTheDetail() {
        let event = TerminalTimelineEvent(
            sessionID: 1, type: "scrollback:exited",
            paneKind: .shell, source: "views/terminal",
            detail: ["reason": "dismissed"]
        )

        XCTAssertEqual(event.detail["pane"] as? String, "shell")
        XCTAssertEqual(event.detail["reason"] as? String, "dismissed")
    }

    func testTheMergedPaneMatchesTheKindItWasGiven() {
        for kind in [TerminalPaneKind.session, .shell] {
            let event = TerminalTimelineEvent(
                sessionID: 1, type: "t", paneKind: kind, source: "s"
            )
            XCTAssertEqual(event.detail["pane"] as? String, kind.rawValue)
        }
    }

    /// A caller that sets the key itself must not silently win over the kind it
    /// also passed — the two disagreeing is worse than either alone.
    func testTheKindWinsOverAPaneKeyInTheDetail() {
        let event = TerminalTimelineEvent(
            sessionID: 1, type: "t", paneKind: .session,
            source: "s", detail: ["pane": "shell"]
        )

        XCTAssertEqual(event.detail["pane"] as? String, "session")
    }

    // MARK: - The size hint

    func testTheSizeHintDefaultsOff() {
        let event = TerminalTimelineEvent(
            sessionID: 1, type: "t", paneKind: .session, source: "s"
        )

        XCTAssertFalse(event.detailMayBeLarge)
    }

    func testTheSizeHintTravelsToTheRecorder() {
        var recorded: [TerminalTimelineEvent] = []
        let recorder: TerminalTimelineRecorder? = TerminalTimelineRecorder(
            terminalSource: "views/terminal",
            scrollbackSource: "views/scrollback"
        ) {
            recorded.append($0)
        }

        recorder.record(sessionID: 1) { id, _ in
            TerminalTimelineEvent(
                sessionID: id, type: "scrollback:reviewed",
                paneKind: .session, source: "s",
                detail: ["notes": [["note": "a note body"]]],
                detailMayBeLarge: true
            )
        }

        XCTAssertEqual(
            recorded.first?.detailMayBeLarge, true,
            "a recorder passing detail as command arguments needs this to pick "
                + "a transport without a size ceiling"
        )
    }

    // MARK: - Source attribution

    /// The app's own names for where an event came from reach the event
    /// untouched, for both of the places it can come from.
    ///
    /// This is the half of an event that is *identity* rather than vocabulary.
    /// The `type` is shared — every app that opens a scrollback records
    /// `scrollback:entered` — but `source` is what an app calls its own code,
    /// and it is already written into rows that outlive any refactor.
    ///
    /// Asserted because it silently was not. When the emitting code moved into
    /// this package it brought a constant of its own along, and every new row
    /// from that point on disagreed with every row before it about where it
    /// came from. Nothing failed, because nothing was watching.
    func testTheAppsSourcesReachTheEventUntouched() {
        var recorded: [TerminalTimelineEvent] = []
        let recorder: TerminalTimelineRecorder? = TerminalTimelineRecorder(
            terminalSource: "some-app/views/terminal",
            scrollbackSource: "some-app/views/scrollback"
        ) {
            recorded.append($0)
        }

        recorder.record(sessionID: 1) { id, recorder in
            TerminalTimelineEvent(
                sessionID: id, type: "scrollback:entered",
                paneKind: .session, source: recorder.terminalSource
            )
        }
        recorder.record(sessionID: 1) { id, recorder in
            TerminalTimelineEvent(
                sessionID: id, type: "scrollback.note:created",
                paneKind: .session, source: recorder.scrollbackSource
            )
        }

        XCTAssertEqual(
            recorded.map(\.source),
            ["some-app/views/terminal", "some-app/views/scrollback"],
            "shared code stamps what the app supplied, and picks between the "
                + "two by which part of the surface raised the event"
        )
    }

    /// Nothing between the app and the row reformats the value.
    ///
    /// A source is an opaque label the app chose, so shared code must not trim,
    /// normalise, prefix or case-fold it — each of which stays invisible right
    /// up until someone groups a year of rows by it.
    func testNothingBetweenTheAppAndTheRowRewritesASource() {
        let awkward = "  App/Views Terminal_v2 (legacy)  "
        var recorded: [TerminalTimelineEvent] = []
        let recorder: TerminalTimelineRecorder? = TerminalTimelineRecorder(
            terminalSource: awkward,
            scrollbackSource: awkward
        ) {
            recorded.append($0)
        }

        recorder.record(sessionID: 1) { id, recorder in
            TerminalTimelineEvent(
                sessionID: id, type: "scrollback:exited",
                paneKind: .shell, source: recorder.terminalSource
            )
        }

        XCTAssertEqual(recorded.first?.source, awkward)
    }
}
