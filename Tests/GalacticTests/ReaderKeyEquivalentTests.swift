import AppKit
import WebKit
import XCTest

@testable import Galactic

/// Whether a reader answers key equivalents it has no business answering.
///
/// The bug these pin: a host that keeps every tab mounted and switches between
/// them with opacity — deliberate, to preserve each tab's state and make
/// switching instant — leaves a reader open on a tab the user has moved away
/// from still sitting in the window. `performKeyEquivalent` is offered to the
/// whole view hierarchy before the menu bar sees the event, and a zero alpha is
/// not `isHidden`, so that reader went on claiming ⌘=/⌘-/⌘0 and scaling a page
/// nobody could see while the menu items those chords belonged to were never
/// reached.
///
/// Only the declining side is asserted. Accepting runs the zoom through
/// JavaScript on a live page, which is a different kind of test and is covered
/// where the rest of the reader's page behaviour is.
final class ReaderKeyEquivalentTests: XCTestCase {

    private func reader() -> ReaderWebView {
        ReaderWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: WKWebViewConfiguration()
        )
    }

    /// Command with a bare `=`, `-` or `0` — the three the reader claims for
    /// zoom when it is the surface in front of the user.
    private func zoomEvent(_ character: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }

    /// The reported bug, in three assertions.
    func testAReaderThatIsNotShowingDeclinesTheZoomChords() {
        let view = reader()
        view.isVisibleSurface = false

        for character in ["=", "-", "0"] {
            XCTAssertFalse(
                view.performKeyEquivalent(with: zoomEvent(character)),
                "⌘\(character) must carry on to whatever the user can "
                    + "actually see"
            )
        }
    }

    /// A host that forgets to say gets a reader that declines rather than one
    /// that steals.
    ///
    /// Which way this defaults is the whole reason the host-facing parameter on
    /// `ReaderHostView` is required and not defaulted: `true` would reproduce
    /// the bug silently in any host that missed it, where a missed `false`
    /// shows up as a chord that does nothing — visible, and traceable to the
    /// one line that explains it.
    func testTheDefaultIsToDecline() {
        XCTAssertFalse(
            reader().isVisibleSurface,
            "not showing until a host says otherwise"
        )
    }

    /// Function keys are swallowed to stop them ringing the system beep, and
    /// that too is only this reader's business while it is the one on screen.
    func testAReaderThatIsNotShowingDoesNotSwallowFunctionKeys() {
        let view = reader()
        view.isVisibleSurface = false

        // F5, in the private-use range AppKit reports function keys in.
        let f5 = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .function,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{F708}",
            charactersIgnoringModifiers: "\u{F708}",
            isARepeat: false,
            keyCode: 96
        )!

        XCTAssertFalse(view.performKeyEquivalent(with: f5))
    }
}
