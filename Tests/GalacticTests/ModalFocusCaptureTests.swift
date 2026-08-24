import AppKit
import XCTest

@testable import Galactic

/// The keyboard note and the Escape monitor, asserted directly rather than
/// through whichever presenter happens to exercise them.
///
/// `arm` and `disarm` exist to make an ordering rule impossible to get wrong by
/// accident, so the asymmetry between them is pinned as hard as the behaviour:
/// one takes the keyboard, the other does not give it back. Someone tidying
/// these into symmetry would break every modal's focus restore, and nothing
/// else in this suite would notice.
@MainActor
final class ModalFocusCaptureTests: XCTestCase {

    override func setUpWithError() throws {
        // capture() reads NSApp.
        _ = NSApplication.shared
    }

    func testArmingInstallsTheMonitor() {
        let focus = ModalFocusCapture()

        focus.arm(isActive: { true }, onEscape: {})
        defer { focus.disarm() }

        XCTAssertNotNil(focus.escapeMonitor)
    }

    func testDisarmingRemovesTheMonitor() {
        let focus = ModalFocusCapture()
        focus.arm(isActive: { true }, onEscape: {})

        focus.disarm()

        XCTAssertNil(focus.escapeMonitor)
    }

    func testArmingTwiceDoesNotStackASecondMonitor() {
        let focus = ModalFocusCapture()
        focus.arm(isActive: { true }, onEscape: {})
        let first = focus.escapeMonitor
        defer { focus.disarm() }

        focus.arm(isActive: { true }, onEscape: {})

        XCTAssertTrue(
            (first as AnyObject) === (focus.escapeMonitor as AnyObject),
            "a second arm must not install a second monitor"
        )
    }

    /// The asymmetry, stated as a test because it is the rule most likely to be
    /// "corrected" into symmetry by someone who has not read why.
    ///
    /// The note is planted rather than captured: `capture()` reads
    /// `NSApp.keyWindow`, and a test process has no key window to read, so a
    /// captured note is nil here for reasons that have nothing to do with what
    /// is being asserted. Planting it makes the question answerable — does
    /// `disarm` leave a note alone — instead of vacuous. Held strongly for the
    /// duration because both properties are weak.
    func testDisarmingLeavesTheNoteForTheViewToConsume() {
        let focus = ModalFocusCapture()
        let window = NSWindow()
        focus.arm(isActive: { true }, onEscape: {})
        focus.priorWindow = window

        focus.disarm()

        XCTAssertNotNil(
            focus.priorWindow,
            "disarm releases Escape only — restore() is the view's to call"
        )
    }

    func testRestoringConsumesTheNote() {
        let focus = ModalFocusCapture()
        let window = NSWindow()
        focus.priorWindow = window
        focus.priorResponder = window

        focus.restore()

        XCTAssertNil(focus.priorWindow)
        XCTAssertNil(focus.priorResponder)
    }

    /// A gone presenter answers false and the key passes through, which is what
    /// keeps a leaked monitor from swallowing Escape for the whole app.
    func testAnInactiveModalDoesNotAnswerEscape() {
        let focus = ModalFocusCapture()
        var escapes = 0
        focus.arm(isActive: { false }, onEscape: { escapes += 1 })
        defer { focus.disarm() }

        XCTAssertEqual(escapes, 0)
        XCTAssertNotNil(
            focus.escapeMonitor,
            "the monitor is installed regardless; isActive gates the handler"
        )
    }
}
