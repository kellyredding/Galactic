import AppKit
import XCTest

@testable import Galactic

/// The go-to-line prompt's lifecycle.
///
/// `ReaderLineJumpTests` covers what a typed string means and what the emitted
/// script says. Nothing covered opening, closing, the monitor, or whether the
/// jump is delivered at all — which is the half a host depends on, and the half
/// a cross-file searcher clicking a line number leans on entirely.
@MainActor
final class LineJumpPresenterTests: XCTestCase {

    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    // MARK: - Opening and closing

    func testToggleOpensThenCloses() {
        let p = LineJumpPresenter()

        p.toggle()
        XCTAssertTrue(p.isPresented)

        p.toggle()
        XCTAssertFalse(p.isPresented)
    }

    func testPresentingClearsWhatWasTypedLastTime() {
        let p = LineJumpPresenter()
        p.present(lineCount: 50)
        p.query = "42"
        p.dismiss()

        p.present(lineCount: 50)

        XCTAssertEqual(
            p.query, "",
            "a reopened prompt starts empty; a line number is not a search"
        )
    }

    func testTheLineCountIsHeldForThePlaceholder() {
        let p = LineJumpPresenter()

        p.present(lineCount: 120)

        XCTAssertEqual(p.lineCount, 120)
    }

    func testAPromptCanBeOpenedWithoutALineCount() {
        let p = LineJumpPresenter()

        p.present()

        XCTAssertTrue(p.isPresented)
        XCTAssertNil(p.lineCount)
    }

    func testASecondPresentIsIgnoredRatherThanReopening() {
        let p = LineJumpPresenter()
        p.present(lineCount: 10)
        p.query = "7"

        p.present(lineCount: 99)

        XCTAssertEqual(
            p.query, "7",
            "the guard is against itself; a second present must not clear"
        )
        XCTAssertEqual(p.lineCount, 10)
    }

    func testDismissingAClosedPromptIsHarmless() {
        let p = LineJumpPresenter()

        p.dismiss()

        XCTAssertFalse(p.isPresented)
    }

    func testTheEscapeMonitorLivesExactlyAsLongAsThePrompt() {
        let p = LineJumpPresenter()
        XCTAssertNil(p.focus.escapeMonitor)

        p.present(lineCount: 10)
        XCTAssertNotNil(p.focus.escapeMonitor)

        p.dismiss()
        XCTAssertNil(p.focus.escapeMonitor)
    }

    func testASecondPresentDoesNotStackASecondMonitor() {
        let p = LineJumpPresenter()
        p.present(lineCount: 10)
        let first = p.focus.escapeMonitor
        defer { p.dismiss() }

        p.present(lineCount: 10)

        XCTAssertTrue(
            (first as AnyObject) === (p.focus.escapeMonitor as AnyObject)
        )
    }

    // MARK: - Delivering the jump

    func testCommittingDeliversTheLine() {
        let p = LineJumpPresenter()
        var jumped: [Int] = []
        p.onJump = { jumped.append($0) }
        p.present(lineCount: 100)
        p.query = "42"

        p.commit()

        XCTAssertEqual(jumped, [42])
    }

    /// Dismissed before the jump fires, so a host that jumps synchronously need
    /// not think about ordering — the same rule the picker's open follows.
    func testCommittingDismissesBeforeDelivering() {
        let p = LineJumpPresenter()
        var presentedWhenJumped: Bool?
        p.onJump = { [weak p] _ in presentedWhenJumped = p?.isPresented }
        p.present(lineCount: 100)
        p.query = "7"

        p.commit()

        XCTAssertEqual(presentedWhenJumped, false)
    }

    func testCommittingSomethingThatIsNotALineClosesSilently() {
        let p = LineJumpPresenter()
        var jumped = 0
        p.onJump = { _ in jumped += 1 }
        p.present(lineCount: 100)
        p.query = "not a line"

        p.commit()

        XCTAssertFalse(p.isPresented)
        XCTAssertEqual(
            jumped, 0, "nil means do nothing rather than complain"
        )
    }

    func testCommittingWithNoHandlerIsHarmless() {
        let p = LineJumpPresenter()
        p.present(lineCount: 100)
        p.query = "3"

        p.commit()

        XCTAssertFalse(p.isPresented)
    }

    /// Past the end is the script's problem, not the prompt's: it clamps to the
    /// last line rather than refusing, so the prompt must not pre-empt that by
    /// filtering against `lineCount`.
    func testALineBeyondTheEndIsStillDelivered() {
        let p = LineJumpPresenter()
        var jumped: [Int] = []
        p.onJump = { jumped.append($0) }
        p.present(lineCount: 10)
        p.query = "9999"

        p.commit()

        XCTAssertEqual(jumped, [9999])
    }

    // MARK: - Standing down

    func testTheKeyboardClaimFollowsPresentation() {
        let p = LineJumpPresenter.shared
        defer { p.dismiss() }
        XCTAssertFalse(LineJumpPresenter.isClaimingKeyboard)

        p.present(lineCount: 10)

        XCTAssertTrue(LineJumpPresenter.isClaimingKeyboard)
    }

    func testTheModalRegisterSeesAnOpenPrompt() {
        let p = LineJumpPresenter.shared
        defer { p.dismiss() }

        p.present(lineCount: 10)

        XCTAssertTrue(GalacticModals.isClaimingKeyboard)
    }
}
