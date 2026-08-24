import AppKit
import XCTest

@testable import Galactic

/// The search panel's lifecycle, its seams, and its per-owner memory.
///
/// The engine has its own suite against a real corpus; what only this file can
/// assert is the modal behaviour and the state that survives a close — plus the
/// mutual exclusion with the picker, which is the one piece of cross-presenter
/// coupling in the package and therefore the one nothing else would catch.
@MainActor
final class FileSearchPresenterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-presenter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func presenter(owner: @escaping () -> String = { "default" })
        -> FileSearchPresenter
    {
        let p = FileSearchPresenter()
        p.rootProvider = { [weak self] in self?.root }
        p.ownerProvider = owner
        return p
    }

    // MARK: - Opening and closing

    func testToggleOpensThenCloses() {
        let p = presenter()

        p.toggle()
        XCTAssertTrue(p.isPresented)

        p.toggle()
        XCTAssertFalse(p.isPresented)
    }

    func testTheRootIsAskedForEveryTimeItOpens() {
        var asked = 0
        let p = presenter()
        p.rootProvider = { [weak self] in
            asked += 1
            return self?.root
        }

        p.present()
        p.dismiss()
        p.present()

        XCTAssertEqual(asked, 2, "never cached — a host is free to re-root")
    }

    func testASecondPresentIsIgnored() {
        let p = presenter()
        p.present()
        p.query = "typed"

        p.present()

        XCTAssertEqual(
            p.query, "typed", "the guard is against itself, not a reset"
        )
    }

    func testDismissingAClosedPanelIsHarmless() {
        let p = presenter()
        p.dismiss()
        XCTAssertFalse(p.isPresented)
    }

    func testTheEscapeMonitorLivesExactlyAsLongAsThePanel() {
        let p = presenter()
        XCTAssertNil(p.focus.escapeMonitor)

        p.present()
        XCTAssertNotNil(p.focus.escapeMonitor)

        p.dismiss()
        XCTAssertNil(p.focus.escapeMonitor)
    }

    func testASecondPresentDoesNotStackASecondMonitor() {
        let p = presenter()
        p.present()
        let first = p.focus.escapeMonitor
        defer { p.dismiss() }

        p.present()

        XCTAssertTrue(
            (first as AnyObject) === (p.focus.escapeMonitor as AnyObject)
        )
    }

    // MARK: - Per-owner memory

    func testAQueryComesBackForTheSameOwner() {
        let p = presenter()
        p.present()
        p.query = "needle"
        p.dismiss()

        p.present()

        XCTAssertEqual(p.query, "needle")
    }

    func testTheCaseSettingComesBackToo() {
        let p = presenter()
        p.present()
        p.toggleCaseSensitivity()
        XCTAssertTrue(p.isCaseSensitive)
        p.dismiss()

        p.present()

        XCTAssertTrue(p.isCaseSensitive)
    }

    func testTwoOwnersKeepSeparateQueries() {
        var owner = "a"
        let p = presenter(owner: { owner })

        p.present()
        p.query = "alpha"
        p.dismiss()

        owner = "b"
        p.present()
        XCTAssertEqual(p.query, "", "a set that has never searched starts empty")
        p.query = "beta"
        p.dismiss()

        owner = "a"
        p.present()
        XCTAssertEqual(p.query, "alpha")

        p.dismiss()
        owner = "b"
        p.present()
        XCTAssertEqual(p.query, "beta")
    }

    /// A host may switch file sets while the panel is open. The owner is
    /// captured when it opens, so what it remembers goes back to the set it was
    /// opened for — asking again on the way out filed one set's query under
    /// another set's key, and both then read back the wrong one.
    func testSwitchingSetsWhileOpenDoesNotMisfileTheQuery() {
        var owner = "a"
        let p = presenter(owner: { owner })
        p.present()
        p.query = "alpha"

        owner = "b"
        p.dismiss()

        p.present()
        XCTAssertEqual(
            p.query, "",
            "set b has never been searched and must not inherit a's query"
        )

        p.dismiss()
        owner = "a"
        p.present()
        XCTAssertEqual(p.query, "alpha", "and a's own query is intact")
    }

    /// A query is about a root. Answering a remembered one against a different
    /// root would be a different question.
    func testAChangedRootDiscardsTheSavedQuery() throws {
        let p = presenter()
        p.present()
        p.query = "needle"
        p.dismiss()

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: other, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: other) }
        p.rootProvider = { other }

        p.present()

        XCTAssertEqual(p.query, "")
        XCTAssertFalse(p.isCaseSensitive)
    }

    // MARK: - Searching

    func testCommittingAnEmptyQueryDoesNothing() {
        let p = presenter()
        var runs = 0
        p.onRun = { _ in runs += 1 }
        p.present()
        p.query = "   "

        p.commit()

        XCTAssertEqual(runs, 0)
        XCTAssertTrue(p.isPresented, "and the panel stays up to be corrected")
    }

    func testTheContextSettingIsAskedOfTheHost() async throws {
        let p = presenter()
        var asked = 0
        p.contextLinesProvider = {
            asked += 1
            return 4
        }
        p.present()
        p.query = "needle"

        let run = await committedRun(p)

        XCTAssertGreaterThan(asked, 0)
        XCTAssertEqual(run.query.contextLines, 4)
    }

    func testTheCaseSettingReachesTheRun() async throws {
        let p = presenter()
        p.present()
        p.query = "needle"
        p.toggleCaseSensitivity()

        let run = await committedRun(p)

        XCTAssertEqual(run.query.isCaseSensitive, true)
    }

    func testTheQueryIsTrimmedBeforeItIsRun() async throws {
        let p = presenter()
        p.present()
        p.query = "  needle  "

        let run = await committedRun(p)

        XCTAssertEqual(run.query.text, "needle")
    }

    /// Dismissed before handing over, like the picker's open, so a host acting
    /// synchronously need not think about ordering.
    func testTheRunIsDeliveredAfterThePanelHasClosed() async throws {
        let p = presenter()
        p.present()
        p.query = "needle"

        var presentedWhenDelivered: Bool?
        _ = await committedRun(p) { _ in
            presentedWhenDelivered = p.isPresented
        }

        XCTAssertEqual(presentedWhenDelivered, false)
    }

    func testTheLastRunIsRememberedForTheOwner() async throws {
        let p = presenter()
        p.present()
        p.query = "needle"

        _ = await committedRun(p)

        p.present()
        XCTAssertNotNil(
            p.lastRun, "so the panel can summarise what it last found"
        )
    }

    // MARK: - Standing down

    func testTheKeyboardClaimFollowsPresentation() {
        let p = FileSearchPresenter.shared
        defer {
            p.dismiss()
            p.rootProvider = { nil }
        }
        p.rootProvider = { nil }
        XCTAssertFalse(FileSearchPresenter.isClaimingKeyboard)

        p.present()

        XCTAssertTrue(FileSearchPresenter.isClaimingKeyboard)
    }

    func testTheModalRegisterSeesAnOpenPanel() {
        let p = FileSearchPresenter.shared
        defer {
            p.dismiss()
            p.rootProvider = { nil }
        }
        p.rootProvider = { nil }

        p.present()

        XCTAssertTrue(GalacticModals.isClaimingKeyboard)
        XCTAssertTrue(ModalState.isPresenting(over: nil))
    }

    // MARK: - One card at a time

    func testOpeningTheSearcherClosesThePicker() {
        let picker = FilePickerPresenter.shared
        let searcher = FileSearchPresenter.shared
        defer {
            picker.dismiss()
            searcher.dismiss()
            picker.rootProvider = { nil }
            searcher.rootProvider = { nil }
        }
        picker.rootProvider = { nil }
        searcher.rootProvider = { nil }
        picker.present()
        XCTAssertTrue(picker.isPresented)

        searcher.present()

        XCTAssertFalse(
            picker.isPresented,
            "two cards at the same anchor would overlap"
        )
        XCTAssertTrue(searcher.isPresented)
    }

    func testOpeningThePickerClosesTheSearcher() {
        let picker = FilePickerPresenter.shared
        let searcher = FileSearchPresenter.shared
        defer {
            picker.dismiss()
            searcher.dismiss()
            picker.rootProvider = { nil }
            searcher.rootProvider = { nil }
        }
        picker.rootProvider = { nil }
        searcher.rootProvider = { nil }
        searcher.present()
        XCTAssertTrue(searcher.isPresented)

        picker.present()

        XCTAssertFalse(searcher.isPresented)
        XCTAssertTrue(picker.isPresented)
    }

    // MARK: - Helper

    /// Commit and await the run.
    ///
    /// Awaited rather than spun: this class is `@MainActor` and so is the
    /// presenter's completion, so pumping the run loop here would block the
    /// actor the result needs in order to arrive. The first version of this
    /// helper did exactly that and every search test timed out.
    private func committedRun(
        _ p: FileSearchPresenter,
        extra: @escaping (FileSearchRun) -> Void = { _ in }
    ) async -> FileSearchRun {
        await withCheckedContinuation { continuation in
            var resumed = false
            p.onRun = { run in
                extra(run)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: run)
            }
            p.commit()
        }
    }
}
