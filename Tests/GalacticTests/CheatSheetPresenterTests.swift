import AppKit
import XCTest
@testable import Galactic

/// When the sheet reads its contents, and what stands down when it closes.
///
/// The snapshot's timing is the whole reason there is a presenter: the sheet's
/// own search field takes first responder as it appears, so a host resolving
/// availability after that point sees "the user is typing" and dims every chord
/// row. Asking once, at present time, is what makes that structural.
@MainActor
final class CheatSheetPresenterTests: XCTestCase {

    private func sections(label: String) -> [CheatSheetSection] {
        [
            CheatSheetSection(
                id: "terminal", title: "Terminal & Agent",
                rows: [
                    CheatSheetRow(
                        id: "terminal.0", keys: "⇧⌘⌫", label: label,
                        condition: "", isActive: true
                    )
                ]
            )
        ]
    }

    // MARK: - The snapshot

    func testTheSectionsProviderIsAskedOnlyWhenTheSheetOpens() {
        var asked = 0
        let presenter = CheatSheetPresenter()
        presenter.sectionsProvider = {
            asked += 1
            return []
        }

        XCTAssertEqual(asked, 0, "constructing the presenter asks nothing")

        presenter.present()
        XCTAssertEqual(asked, 1)

        presenter.present()
        XCTAssertEqual(
            asked, 1,
            "a second present while open must not re-read: by then the "
                + "search field holds focus, and the fresh answer would dim "
                + "every row"
        )

        presenter.dismiss()
        presenter.present()
        XCTAssertEqual(asked, 2, "each open takes its own snapshot")
    }

    /// The bug this whole arrangement exists for, stated as an assertion: what
    /// the sheet renders is what was true when it opened.
    func testTheSnapshotIsHeldRatherThanReRead() {
        let presenter = CheatSheetPresenter()
        var live = "Clear session"
        presenter.sectionsProvider = {
            [
                CheatSheetSection(
                    id: "terminal", title: "Terminal & Agent",
                    rows: [
                        CheatSheetRow(
                            id: "terminal.0", keys: "⇧⌘⌫", label: live,
                            condition: "", isActive: true
                        )
                    ]
                )
            ]
        }

        presenter.present()
        live = "Compact session"

        XCTAssertEqual(
            presenter.sections.first?.rows.first?.label, "Clear session",
            "the sheet shows what was true when it opened, not what is true "
                + "now"
        )
    }

    /// Not cleared on dismiss, on purpose: a host fades the overlay out, so
    /// emptying the snapshot would flash a blank card on the way down.
    func testDismissLeavesTheSnapshotStandingForTheCloseAnimation() {
        let presenter = CheatSheetPresenter()
        presenter.sectionsProvider = { self.sections(label: "Clear session") }

        presenter.present()
        presenter.dismiss()

        XCTAssertFalse(presenter.isPresented)
        XCTAssertFalse(presenter.sections.isEmpty)
    }

    /// A host that never wires the provider gets an empty sheet, not a crash
    /// — and `CheatSheetView`'s empty state says so in words rather than
    /// reporting it as a query that matched nothing.
    func testAnUnwiredProviderOpensAnEmptySheet() {
        let presenter = CheatSheetPresenter()

        presenter.present()

        XCTAssertTrue(presenter.isPresented)
        XCTAssertTrue(presenter.sections.isEmpty)
    }

    // MARK: - Opening and closing

    func testToggleOpensThenCloses() {
        let presenter = CheatSheetPresenter()

        presenter.toggle()
        XCTAssertTrue(presenter.isPresented)

        presenter.toggle()
        XCTAssertFalse(
            presenter.isPresented,
            "the chord that summons the sheet has to put it away too"
        )
    }

    /// The monitor is app-wide — `addLocalMonitorForEvents` is not view-scoped
    /// — so one left installed would swallow Escape everywhere else in the
    /// host. Installed only while presented is the claim; this is the check.
    func testTheEscapeMonitorLivesExactlyAsLongAsTheSheet() {
        let presenter = CheatSheetPresenter()

        XCTAssertNil(presenter.escapeMonitor)

        presenter.present()
        XCTAssertNotNil(presenter.escapeMonitor)

        presenter.dismiss()
        XCTAssertNil(presenter.escapeMonitor)
    }

    func testDismissingAClosedSheetIsHarmless() {
        let presenter = CheatSheetPresenter()

        presenter.present()
        presenter.dismiss()
        presenter.dismiss()

        XCTAssertNil(presenter.escapeMonitor)
        XCTAssertFalse(presenter.isPresented)
    }

    // MARK: - Where the sheet opens

    /// Read at the same moment as the sections, so the two cannot disagree
    /// about a sheet the host has since rebuilt.
    func testTheOpeningSectionArrivesWithTheSections() {
        let presenter = CheatSheetPresenter()
        var asked = 0
        presenter.sectionsProvider = {
            asked += 1
            return [
                CheatSheetSection(id: "sessions", title: "Sessions", rows: []),
                CheatSheetSection(
                    id: "terminal", title: "Terminal & Agent", rows: [],
                    isOpening: true),
            ]
        }

        presenter.present()

        XCTAssertEqual(
            presenter.sections.first(where: \.isOpening)?.id, "terminal",
            "the marked section travels with the snapshot that produced it")
        XCTAssertEqual(
            asked, 1,
            "one provider, so the rows and the scroll target cannot be "
                + "computed from two different snapshots")
    }

    /// A host that marks nothing scrolls nowhere — which is what a scroll view
    /// does by default anyway.
    func testNoOpeningSectionIsTheDefault() {
        let presenter = CheatSheetPresenter()
        presenter.sectionsProvider = {
            [CheatSheetSection(id: "only", title: "Only", rows: [])]
        }

        presenter.present()

        XCTAssertNil(presenter.sections.first(where: \.isOpening))
    }

    /// Several marked sections degrade to the earliest rather than fighting.
    func testTheFirstMarkedSectionWins() {
        let presenter = CheatSheetPresenter()
        presenter.sectionsProvider = {
            [
                CheatSheetSection(
                    id: "a", title: "A", rows: [], isOpening: true),
                CheatSheetSection(
                    id: "b", title: "B", rows: [], isOpening: true),
            ]
        }

        presenter.present()

        XCTAssertEqual(presenter.sections.first(where: \.isOpening)?.id, "a")
    }

    // MARK: - Handing the keyboard back

    /// Closing releases the note, whether or not it could be acted on.
    ///
    /// The bug the note exists to fix: closing the sheet left the keyboard
    /// nowhere, so a terminal session that had focus before ⌘/ did not get it
    /// back and the next thing typed went wherever the window settled.
    ///
    /// Asserted through the bookkeeping, not the caret. Moving first responder
    /// for real needs a running app and an event loop, and a window built in
    /// this target crashes the process outright — the same wall
    /// `SheetAlertFocusTests` names when it leaves activation to manual
    /// verification. A plain responder is enough to prove the note is kept and
    /// dropped at the right times, which is the part that can regress silently.
    ///
    /// Releasing matters beyond the reference: the next open would otherwise
    /// find a stale note and hand the keyboard to whatever used to hold it.
    func testRestoringReleasesTheNote() {
        let presenter = CheatSheetPresenter()
        presenter.present()

        // Held strongly here on purpose. The note is weak, so an inline
        // `NSResponder()` would be gone before the assertion ran and the test
        // would pass whether or not anything cleared it.
        let responder = NSResponder()
        presenter.priorResponder = responder
        XCTAssertNotNil(
            presenter.priorResponder,
            "precondition: something is noted, so nil below means released")

        presenter.restoreFocus()

        XCTAssertNil(presenter.priorResponder, "the note is released")
        XCTAssertNil(presenter.priorWindow, "and so is the window it was in")
    }

    /// Dismissing does *not* restore, and that is the fix rather than an
    /// oversight.
    ///
    /// The bug: restoring inside `dismiss` put the caret back and then lost it,
    /// because SwiftUI clears first responder when it tears down a field whose
    /// focus binding still reads true — which happens a pass or an animation
    /// after `dismiss` returns. The view now restores as it disappears, so the
    /// note has to survive the dismiss that precedes it.
    func testDismissLeavesTheNoteForTheViewToActOn() {
        let presenter = CheatSheetPresenter()
        presenter.present()

        let responder = NSResponder()
        presenter.priorResponder = responder

        presenter.dismiss()

        XCTAssertTrue(
            presenter.priorResponder === responder,
            "the note outlives dismiss, because the only safe moment to act "
                + "on it is once the overlay has actually gone")
    }

    /// Restoring twice is harmless, so a host that dismisses a sheet whose view
    /// never mounted cannot strand anything.
    func testRestoringIsIdempotent() {
        let presenter = CheatSheetPresenter()
        presenter.present()
        let responder = NSResponder()
        presenter.priorResponder = responder

        presenter.restoreFocus()
        presenter.restoreFocus()

        XCTAssertNil(presenter.priorResponder)
    }

    /// A second open while already up must not overwrite the note.
    ///
    /// Same hazard the sections have, one step further on: by the time the
    /// sheet is up its own search field holds first responder, so re-noting
    /// would record the sheet as the thing to hand the keyboard back to — and
    /// closing would then restore focus to a field that no longer exists.
    func testASecondOpenDoesNotRenoteTheKeyboard() {
        let presenter = CheatSheetPresenter()
        presenter.present()

        let planted = NSResponder()
        presenter.priorResponder = planted

        presenter.present()   // already up — must be a no-op

        XCTAssertTrue(
            presenter.priorResponder === planted,
            "the note survives a redundant open, so the caret still goes back "
                + "to where the user actually was")
    }

    // MARK: - The fourth presentation mechanism

    /// `ModalState` is where a drag target asks whether something is being
    /// presented over it. The sheet is an in-window overlay holding the
    /// keyboard, so a drop landing behind it has the same problem a drop behind
    /// an alert sheet does: input directed somewhere the user cannot see.
    ///
    /// Uses the singleton, because that is what `ModalState` reads.
    func testAnOpenCheatSheetCountsAsAPresentation() {
        // Force NSApplication into existence before asking it anything, since
        // `ModalState` reads `NSApp.modalWindow` first.
        _ = NSApplication.shared
        let presenter = CheatSheetPresenter.shared
        defer { presenter.dismiss() }

        XCTAssertFalse(
            ModalState.isPresenting(over: nil),
            "nothing else in this target should leave a presentation up"
        )

        presenter.present()

        XCTAssertTrue(
            ModalState.isPresenting(over: nil),
            "a fourth mechanism is registered in the helper, not in each "
                + "drag handler"
        )
    }

    /// The stand-down gate every other local key monitor reads. A gate, not an
    /// ordering assumption: AppKit does not contract monitor order, and the
    /// sheet already lost this race to a reader's monitor once.
    func testTheKeyboardClaimFollowsPresentation() {
        let presenter = CheatSheetPresenter.shared
        defer { presenter.dismiss() }

        XCTAssertFalse(CheatSheetPresenter.isClaimingKeyboard)

        presenter.present()

        XCTAssertTrue(CheatSheetPresenter.isClaimingKeyboard)
    }
}
