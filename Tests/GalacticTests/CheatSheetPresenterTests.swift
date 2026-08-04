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
