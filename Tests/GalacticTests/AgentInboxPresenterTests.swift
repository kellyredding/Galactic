import AppKit
import XCTest

@testable import Galactic

/// What the inbox modal borrows while it is up, and gives back when it goes.
///
/// The focus note and the Escape monitor here are the same mechanism
/// `CheatSheetPresenter` carries, arrived at through the same bugs — a caret
/// that never came back, and an Escape that closed the modal *and* reached the
/// terminal behind it. Only the sheet's copy was ever asserted. These pin the
/// other one, so that folding the two into a shared value has something to be
/// measured against rather than eyeballed.
///
/// Asserted through the bookkeeping rather than the caret, for the reason
/// `CheatSheetPresenterTests` gives: moving first responder for real needs a
/// running app and an event loop, and a window built in this target crashes the
/// process. What can regress silently is whether the note is taken, kept and
/// released at the right moments, and that is reachable.
@MainActor
final class AgentInboxPresenterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `captureFocus` reads `NSApp`, which is implicitly unwrapped and nil
        // until something asks for the shared application — so `present()`
        // traps in a bare test process. Forced here rather than left to the
        // alphabetical ordering that happens to rescue the cheat sheet's suite.
        _ = NSApplication.shared
    }

    // MARK: - Opening and closing

    func testToggleOpensThenCloses() {
        let presenter = AgentInboxPresenter()

        presenter.toggle()
        XCTAssertTrue(presenter.isPresented)

        presenter.toggle()
        XCTAssertFalse(presenter.isPresented)
    }

    func testDismissingAClosedModalIsHarmless() {
        let presenter = AgentInboxPresenter()

        presenter.dismiss()

        XCTAssertFalse(presenter.isPresented)
        XCTAssertNil(presenter.focus.escapeMonitor)
    }

    /// Opening with nothing wired is supported and deliberate: a reader who
    /// asks what is waiting deserves an answer when the answer is "there is no
    /// agent", rather than a keystroke that appears not to have worked.
    func testAnUnwiredProviderOpensWithNoQueue() {
        let presenter = AgentInboxPresenter()

        presenter.present()

        XCTAssertTrue(presenter.isPresented)
        XCTAssertNil(presenter.inbox)
        XCTAssertNil(presenter.consumer)
    }

    /// Which queue is resolved as the modal opens, not before and not on every
    /// redraw. The contents stay live afterwards — that is where this parts
    /// company with the cheat sheet — but the choice of queue does not.
    func testTheProvidersAreAskedOnlyWhenTheModalOpens() {
        let presenter = AgentInboxPresenter()
        var asked = 0
        let inbox = AgentInbox()
        presenter.inboxProvider = {
            asked += 1
            return inbox
        }

        XCTAssertEqual(asked, 0, "wiring a provider must not ask it")

        presenter.present()

        XCTAssertEqual(asked, 1)
        XCTAssertTrue(presenter.inbox === inbox)
    }

    /// A redundant open must not re-resolve, for the same reason it must not
    /// re-note the keyboard: by then the modal is what is on screen.
    func testASecondPresentDoesNotReResolveTheQueue() {
        let presenter = AgentInboxPresenter()
        var asked = 0
        presenter.inboxProvider = {
            asked += 1
            return AgentInbox()
        }

        presenter.present()
        presenter.present()

        XCTAssertEqual(asked, 1, "already up — the second open is a no-op")
    }

    // MARK: - The Escape monitor

    /// Installed on open and removed on close, with nothing left behind. A
    /// monitor that outlives its modal answers Escape for a surface that is no
    /// longer there.
    func testTheEscapeMonitorLivesExactlyAsLongAsTheModal() {
        let presenter = AgentInboxPresenter()
        XCTAssertNil(presenter.focus.escapeMonitor, "nothing installed while closed")

        presenter.present()
        XCTAssertNotNil(presenter.focus.escapeMonitor)

        presenter.dismiss()
        XCTAssertNil(presenter.focus.escapeMonitor, "and removed again on close")
    }

    /// A redundant open must not install a second monitor over the first —
    /// the first would then be unreachable and never removed.
    func testASecondPresentDoesNotStackASecondMonitor() {
        let presenter = AgentInboxPresenter()

        presenter.present()
        let installed = presenter.focus.escapeMonitor
        presenter.present()

        XCTAssertTrue(
            (installed as AnyObject?) === (presenter.focus.escapeMonitor as AnyObject?),
            "the monitor from the first open is the one still installed"
        )
    }

    // MARK: - The focus note

    /// Closing releases the note, whether or not it could be acted on. A stale
    /// note would hand the keyboard to whatever used to hold it on the next
    /// open.
    func testRestoringReleasesTheNote() {
        let presenter = AgentInboxPresenter()
        presenter.present()

        // Held strongly on purpose: the note is weak, so an inline
        // `NSResponder()` would be gone before the assertion ran and the test
        // would pass whether or not anything released it.
        let responder = NSResponder()
        presenter.focus.priorResponder = responder
        XCTAssertNotNil(presenter.focus.priorResponder, "precondition")

        presenter.restoreFocus()

        XCTAssertNil(presenter.focus.priorResponder, "the note is released")
        XCTAssertNil(presenter.focus.priorWindow, "and so is the window it was in")
    }

    /// Dismissing does not restore, and that is the fix rather than an
    /// oversight: the view restores as it disappears, so the note has to
    /// survive the dismiss that precedes it.
    func testDismissLeavesTheNoteForTheViewToActOn() {
        let presenter = AgentInboxPresenter()
        presenter.present()
        let responder = NSResponder()
        presenter.focus.priorResponder = responder

        presenter.dismiss()

        XCTAssertTrue(
            presenter.focus.priorResponder === responder,
            "the note outlives dismiss, because the only safe moment to act "
                + "on it is once the overlay has actually gone"
        )
    }

    /// Restoring twice is harmless, so a host that dismisses a modal whose
    /// view never mounted cannot strand anything.
    func testRestoringIsIdempotent() {
        let presenter = AgentInboxPresenter()
        presenter.present()
        presenter.focus.priorResponder = NSResponder()

        presenter.restoreFocus()
        presenter.restoreFocus()

        XCTAssertNil(presenter.focus.priorResponder)
    }

    /// A second open must not overwrite the note. By then the modal itself is
    /// what holds the keyboard, and re-noting would record the modal as the
    /// thing to hand it back to.
    func testASecondOpenDoesNotRenoteTheKeyboard() {
        let presenter = AgentInboxPresenter()
        presenter.present()
        let planted = NSResponder()
        presenter.focus.priorResponder = planted

        presenter.present()

        XCTAssertTrue(
            presenter.focus.priorResponder === planted,
            "the note survives a redundant open"
        )
    }

    /// Restoring with nothing noted is a no-op rather than a crash — the path
    /// a modal takes when it opens with no key window at all.
    func testRestoringWithNothingNotedIsHarmless() {
        let presenter = AgentInboxPresenter()
        presenter.present()

        presenter.restoreFocus()

        XCTAssertNil(presenter.focus.priorResponder)
        XCTAssertNil(presenter.focus.priorWindow)
    }

    // MARK: - The stand-down gate

    /// What every other local key monitor reads before answering an unmodified
    /// key. A gate, not an ordering assumption: AppKit does not contract the
    /// order monitors run in.
    ///
    /// Uses the singleton, because that is what the gate is defined over.
    func testTheKeyboardClaimFollowsPresentation() {
        let presenter = AgentInboxPresenter.shared
        defer { presenter.dismiss() }

        XCTAssertFalse(AgentInboxPresenter.isClaimingKeyboard)

        presenter.present()

        XCTAssertTrue(AgentInboxPresenter.isClaimingKeyboard)
    }

    /// And the aggregate every monitor actually consults. Naming the modals in
    /// one place is what makes a new one stand down everywhere at once.
    func testTheModalRegisterSeesAnOpenInbox() {
        let presenter = AgentInboxPresenter.shared
        defer { presenter.dismiss() }

        XCTAssertFalse(
            GalacticModals.isClaimingKeyboard,
            "nothing else in this target should leave a modal up"
        )

        presenter.present()

        XCTAssertTrue(GalacticModals.isClaimingKeyboard)
    }
}
