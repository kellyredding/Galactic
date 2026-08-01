import XCTest
@testable import Galactic

/// Collapsing a burst of bells into one.
///
/// The behaviour that matters is not "fires less often" but *which* attempt
/// survives and when the next one may: a gate that restarts on every dropped
/// attempt goes silent under a continuous stream, and a window shorter than the
/// response lets a second bell begin while the first is still on screen.
final class TerminalBellDebounceTests: XCTestCase {

    /// Short enough to keep the suite quick, long enough that a same-runloop
    /// burst lands well inside it.
    private let window: TimeInterval = 0.2

    /// Let the main queue drain, plus optionally wait out a duration.
    private func settle(_ seconds: TimeInterval = 0) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.02) {
            done.fulfill()
        }
        wait(for: [done], timeout: seconds + 2)
    }

    func testTheFirstBellRuns() {
        let debounce = TerminalBellDebounce(window: window)
        var runs = 0

        debounce.fire { runs += 1 }
        settle()

        XCTAssertEqual(runs, 1, "a bell with nothing in flight must be heard")
    }

    /// The burst this exists for — a rapid stream of BEL bytes.
    func testABurstInsideTheWindowIsCollapsedToOne() {
        let debounce = TerminalBellDebounce(window: window)
        var runs = 0

        for _ in 0..<10 { debounce.fire { runs += 1 } }
        settle()

        XCTAssertEqual(
            runs, 1,
            "ten bells inside one window are one perceived bell"
        )
    }

    func testABellAfterTheWindowRunsAgain() {
        let debounce = TerminalBellDebounce(window: window)
        var runs = 0

        debounce.fire { runs += 1 }
        settle(window)
        debounce.fire { runs += 1 }
        settle()

        XCTAssertEqual(runs, 2, "the gate must open again once the window passes")
    }

    /// The regression a naive implementation invites: resetting the deadline on
    /// every attempt. Under a continuous stream that never reopens the gate, so
    /// a terminal ringing steadily would go silent instead of ringing once per
    /// window.
    func testDroppedAttemptsDoNotExtendTheWindow() {
        // A longer window than the other cases, so the deadline a correct gate
        // uses and the one a resetting gate would use are far enough apart to
        // tell apart on a busy machine.
        let window: TimeInterval = 0.4
        let debounce = TerminalBellDebounce(window: window)
        var runs = 0

        debounce.fire { runs += 1 }
        settle()
        XCTAssertEqual(runs, 1, "the first bell is heard")

        // Four more attempts, all well inside the first window — the last of
        // them lands around 0.26s, so a gate that reset on every attempt would
        // stay shut until ~0.66s.
        for _ in 0..<4 {
            settle(0.04)
            debounce.fire { runs += 1 }
        }
        settle()
        XCTAssertEqual(runs, 1, "every attempt inside the window is dropped")

        // Now past the deadline measured from the accepted run (~0.42s) and
        // comfortably short of where a resetting gate would put it.
        settle(0.22)
        debounce.fire { runs += 1 }
        settle()

        XCTAssertEqual(
            runs, 2,
            "the window is measured from the accepted run, not the last attempt"
        )
    }

    /// Callers hand this engine callbacks that touch AppKit, so where the body
    /// runs is part of the contract rather than an implementation detail.
    func testTheBodyRunsOnTheMainQueue() {
        let debounce = TerminalBellDebounce(window: window)
        var ranOnMain = false
        let done = expectation(description: "body ran")

        DispatchQueue.global().async {
            debounce.fire {
                ranOnMain = Thread.isMainThread
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 2)
        XCTAssertTrue(
            ranOnMain,
            "a bell delivered off the main thread must still respond on it"
        )
    }

    /// Two panes of the same session hold separate gates; one ringing must not
    /// silence the other.
    func testSeparateGatesDoNotInterfere() {
        let session = TerminalBellDebounce(window: window)
        let shell = TerminalBellDebounce(window: window)
        var sessionRuns = 0
        var shellRuns = 0

        session.fire { sessionRuns += 1 }
        shell.fire { shellRuns += 1 }
        settle()

        XCTAssertEqual(sessionRuns, 1)
        XCTAssertEqual(shellRuns, 1, "a sibling pane's bell is a separate event")
    }
}
