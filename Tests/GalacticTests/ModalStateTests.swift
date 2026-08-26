import AppKit
import XCTest

@testable import Galactic

/// The drag gate.
///
/// One test per overlay, deliberately, because the bug this file closes was
/// three overlays being added to the keyboard predicate and not to this one. An
/// aggregate assertion would have passed throughout: the cheat sheet was always
/// covered. "An overlay is covered" has to be asked of each overlay.
@MainActor
final class ModalStateTests: XCTestCase {

    override func setUpWithError() throws {
        _ = NSApplication.shared
    }

    func testNothingPresentingOverNoWindow() {
        XCTAssertFalse(ModalState.isPresenting(over: nil))
    }

    /// Mechanism 1, which had no test until the predicate behind it moved to
    /// `GalacticModals` — and a refactor of the one line nothing asserts is
    /// exactly how a drag gate quietly stops gating.
    func testAnAppModalWindowRefusesADrop() {
        let window = NSWindow()
        let session = NSApp.beginModalSession(for: window)
        defer {
            NSApp.endModalSession(session)
            window.orderOut(nil)
        }

        XCTAssertTrue(ModalState.isPresenting(over: nil))
    }

    func testAnOpenPickerRefusesADrop() {
        let picker = FilePickerPresenter.shared
        defer {
            picker.dismiss()
            picker.rootProvider = { nil }
        }
        picker.rootProvider = { nil }

        picker.present()

        XCTAssertTrue(
            ModalState.isPresenting(over: nil),
            "a drop landing behind the picker was accepted before this"
        )
    }

    func testAnOpenLineJumpPromptRefusesADrop() {
        let prompt = LineJumpPresenter.shared
        defer { prompt.dismiss() }

        prompt.present(lineCount: 10)

        XCTAssertTrue(ModalState.isPresenting(over: nil))
    }

    func testAnOpenInboxRefusesADrop() {
        let inbox = AgentInboxPresenter.shared
        defer {
            inbox.dismiss()
            inbox.inboxProvider = { nil }
        }
        inbox.inboxProvider = { nil }

        inbox.present()

        XCTAssertTrue(ModalState.isPresenting(over: nil))
    }

    func testAnOpenCheatSheetStillRefusesADrop() {
        let sheet = CheatSheetPresenter.shared
        defer {
            sheet.dismiss()
            sheet.sectionsProvider = { [] }
        }
        sheet.sectionsProvider = { [] }

        sheet.present()

        XCTAssertTrue(ModalState.isPresenting(over: nil))
    }

    /// Closing has to restore the answer, or one open modal in a session would
    /// refuse every drop for the rest of it.
    func testClosingTheLastOverlayAcceptsDropsAgain() {
        let prompt = LineJumpPresenter.shared
        prompt.present(lineCount: 10)

        prompt.dismiss()

        XCTAssertFalse(ModalState.isPresenting(over: nil))
    }
}
