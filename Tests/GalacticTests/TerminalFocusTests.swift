import AppKit
import XCTest
@testable import Galactic

/// Handing first responder to a terminal pane.
///
/// Both hosts carried a copy of this, guarded on flags that meant different
/// things — one asked whether its session was selected, the other whether its
/// tab was showing. Neither asked the whole question, which is how a terminal
/// came to take the caret out of a form on another tab.
final class TerminalFocusTests: XCTestCase {

    /// A view that will accept first responder, standing in for a pane.
    private final class AcceptingView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private var window: NSWindow!
    private var pane: AcceptingView!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        pane = AcceptingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(pane)
    }

    override func tearDown() {
        window = nil
        pane = nil
        super.tearDown()
    }

    /// The request defers, so every assertion has to wait a turn.
    private func settle() {
        let done = expectation(description: "runloop settled")
        DispatchQueue.main.async {
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 1)
    }

    // MARK: - The predicate

    /// The whole point of the predicate: a pane that is not the surface in
    /// front of the user does not take the caret, however it came to be asked.
    func testASurfaceThatIsNotVisibleNeitherResolvesNorFocuses() {
        var resolved = false
        TerminalFocus.request(
            in: window,
            isVisibleSurface: false,
            resolveTarget: {
                resolved = true
                return TerminalFocusTarget(responder: self.pane, isLivePane: true)
            },
            onFocusedLivePane: {}
        )
        settle()
        XCTAssertFalse(
            resolved,
            "an invisible surface should not even ask what to focus"
        )
        XCTAssertFalse(
            window.firstResponder === pane,
            "an invisible surface must not take first responder"
        )
    }

    func testAVisibleSurfaceTakesFirstResponder() {
        TerminalFocus.request(
            in: window,
            isVisibleSurface: true,
            resolveTarget: {
                TerminalFocusTarget(responder: self.pane, isLivePane: true)
            },
            onFocusedLivePane: {}
        )
        settle()
        XCTAssertTrue(
            window.firstResponder === pane,
            "the resolved target should hold first responder"
        )
    }

    // MARK: - The live-pane re-pin

    func testFocusingTheLivePaneRepinsTheTail() {
        var repinned = 0
        TerminalFocus.request(
            in: window,
            isVisibleSurface: true,
            resolveTarget: {
                TerminalFocusTarget(responder: self.pane, isLivePane: true)
            },
            onFocusedLivePane: { repinned += 1 }
        )
        settle()
        XCTAssertEqual(repinned, 1, "focusing the live pane should re-pin once")
    }

    /// Someone reading frozen history must not be snapped to the bottom, so
    /// the re-pin is skipped whenever an overlay took focus instead.
    func testFocusingAnOverlayDoesNotRepinTheTail() {
        var repinned = 0
        TerminalFocus.request(
            in: window,
            isVisibleSurface: true,
            resolveTarget: {
                TerminalFocusTarget(responder: self.pane, isLivePane: false)
            },
            onFocusedLivePane: { repinned += 1 }
        )
        settle()
        XCTAssertEqual(
            repinned, 0, "an overlay taking focus must not re-pin the tail"
        )
        XCTAssertTrue(
            window.firstResponder === pane,
            "the overlay target should still have been focused"
        )
    }

    // MARK: - Resolution timing and refusal

    /// What should hold focus can change between asking and applying — an
    /// overlay may appear or go in that turn — so the target is resolved late.
    func testTheTargetIsResolvedAfterTheRequestReturns() {
        var resolvedDuringCall = true
        var returned = false
        TerminalFocus.request(
            in: window,
            isVisibleSurface: true,
            resolveTarget: {
                resolvedDuringCall = !returned
                return TerminalFocusTarget(
                    responder: self.pane, isLivePane: true
                )
            },
            onFocusedLivePane: {}
        )
        returned = true
        settle()
        XCTAssertFalse(
            resolvedDuringCall,
            "the target must be resolved on the next turn, not inline"
        )
    }

    func testResolvingToNothingAbandonsTheRequest() {
        var repinned = 0
        TerminalFocus.request(
            in: window,
            isVisibleSurface: true,
            resolveTarget: { nil },
            onFocusedLivePane: { repinned += 1 }
        )
        settle()
        XCTAssertEqual(repinned, 0, "an abandoned request re-pins nothing")
        XCTAssertFalse(window.firstResponder === pane)
    }

    func testNoWindowIsHarmless() {
        var resolved = false
        TerminalFocus.request(
            in: nil,
            isVisibleSurface: true,
            resolveTarget: {
                resolved = true
                return nil
            },
            onFocusedLivePane: {}
        )
        settle()
        XCTAssertFalse(resolved, "a view with no window has nothing to ask")
    }
}
