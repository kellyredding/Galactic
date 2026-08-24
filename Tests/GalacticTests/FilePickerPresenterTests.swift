import AppKit
import XCTest

@testable import Galactic

/// What the picker resolves when, and what it borrows while it is up.
///
/// The focus and Escape machinery is shared with the cheat sheet and the inbox,
/// so the assertions that matter here are the ones only this modal has: that the
/// root and the corpus are asked for at open time, that an empty query is
/// answered from the host's history without waiting for a walk, and that a
/// query which is a path is not treated as a filter.
@MainActor
final class FilePickerPresenterTests: XCTestCase {

    private var dir: URL!
    private var siblings: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `captureFocus` reads `NSApp`, which is nil until something asks for
        // the shared application.
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-presenter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        for sibling in siblings { try? FileManager.default.removeItem(at: sibling) }
        siblings = []
        try super.tearDownWithError()
    }

    /// A root that is genuinely elsewhere, rather than inside `dir`.
    ///
    /// The distinction is load-bearing now that a directory *inside* an
    /// indexed root is served from that root's shards rather than walked
    /// again. A test that means "a different tree" has to say so with a tree
    /// that is actually different, or it is testing the nesting behaviour by
    /// accident.
    private func sibling(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-sibling-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        siblings.append(url)
        return url
    }

    // MARK: - Opening and closing

    func testToggleOpensThenCloses() {
        let p = FilePickerPresenter()

        p.toggle()
        XCTAssertTrue(p.isPresented)

        p.toggle()
        XCTAssertFalse(p.isPresented)
    }

    func testTheEscapeMonitorLivesExactlyAsLongAsThePicker() {
        let p = FilePickerPresenter()
        XCTAssertNil(p.focus.escapeMonitor)

        p.present()
        XCTAssertNotNil(p.focus.escapeMonitor)

        p.dismiss()
        XCTAssertNil(p.focus.escapeMonitor)
    }

    /// Every open starts clean. A query left over from last time would filter a
    /// tree the reader has since changed.
    func testEachOpenStartsWithAnEmptyQuery() {
        let p = FilePickerPresenter()
        p.present()
        p.query = "leftover"
        p.dismiss()

        p.present()

        XCTAssertEqual(p.query, "")
        XCTAssertEqual(p.selectedIndex, 0)
    }

    /// Asked each time, so a root the host has moved since is picked up without
    /// this caching one.
    func testTheRootIsAskedForOnEveryOpen() {
        let p = FilePickerPresenter()
        var asked = 0
        p.rootProvider = { [dir] in
            asked += 1
            return dir
        }

        p.present()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(p.root, dir)

        p.dismiss()
        p.present()
        XCTAssertEqual(asked, 2)
    }

    func testAHostWithNoRootOpensAndSaysSo() {
        let p = FilePickerPresenter()

        p.present()

        XCTAssertTrue(p.isPresented)
        XCTAssertNil(p.root)
        XCTAssertTrue(p.rows.isEmpty)
    }

    // MARK: - The empty query

    /// Answered from the host's own history, before any walk. Making a reader
    /// wait for a tree to be indexed before they can reopen the file they just
    /// closed would be a wait for nothing.
    func testAnEmptyQueryIsAnsweredWithoutWaitingForTheIndex() {
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var stack = ClosedTabStack()
        stack.push(url: dir.appendingPathComponent("closed.rb"), row: 0)
        p.closedProvider = { stack.entries }
        p.recentProvider = { [self.dir.appendingPathComponent("recent.rb")] }

        p.present()

        XCTAssertEqual(p.rows.map(\.relativePath), ["closed.rb", "recent.rb"])
        XCTAssertEqual(p.rows.map(\.source), [.closed, .recent])
    }

    // MARK: - Selection

    func testSelectionClampsAtBothEnds() {
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var stack = ClosedTabStack()
        for i in 0..<3 {
            stack.push(url: dir.appendingPathComponent("f\(i).rb"), row: 0)
        }
        p.closedProvider = { stack.entries }
        p.present()

        p.moveSelection(by: -1)
        XCTAssertEqual(p.selectedIndex, 0, "no wrap at the top")

        p.moveSelection(by: 99)
        XCTAssertEqual(p.selectedIndex, 2, "and none at the bottom")
    }

    func testSelectionIsHarmlessWithNothingListed() {
        let p = FilePickerPresenter()
        p.present()

        p.moveSelection(by: 1)

        XCTAssertEqual(p.selectedIndex, 0)
    }

    // MARK: - Choosing

    func testOpeningARowDismissesThenHandsOverTheURL() {
        let p = FilePickerPresenter()
        var opened: [URL] = []
        var presentedWhenOpened: Bool?
        p.onOpen = { url in
            opened.append(url)
            presentedWhenOpened = p.isPresented
        }
        p.present()

        let row = FilePickerItem(
            url: dir.appendingPathComponent("a.rb"),
            relativePath: "a.rb", source: .matched
        )
        p.open(row)

        XCTAssertEqual(opened.map(\.lastPathComponent), ["a.rb"])
        XCTAssertEqual(
            presentedWhenOpened, false,
            "dismissed first, so a host opening synchronously need not think "
                + "about ordering"
        )
    }

    func testCommittingWithNothingListedOpensNothing() {
        let p = FilePickerPresenter()
        var opened = 0
        p.onOpen = { _ in opened += 1 }
        p.present()

        p.commit()

        XCTAssertEqual(opened, 0)
    }

    // MARK: - Re-rooting

    func testCommittingAPathThatDoesNotExistDoesNothing() {
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var changed = 0
        p.onChangeRoot = { _ in changed += 1 }
        p.present()

        p.query = "/definitely/not/here"
        p.commit()

        XCTAssertEqual(changed, 0)
    }

    /// A path being typed is not a filter, so the corpus is not consulted — and
    /// the file rows go **at once**, before the directory is read.
    ///
    /// Reading a directory takes long enough to see, and what is showing while
    /// it happens belongs to the previous query: under a half-typed path that
    /// is a list of files, which is precisely what this mode exists not to
    /// show. Clearing after the read would flash the wrong answer.
    func testAPathQueryClearsTheFileRowsBeforeReadingAnything() {
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var stack = ClosedTabStack()
        stack.push(url: dir.appendingPathComponent("closed.rb"), row: 0)
        p.closedProvider = { stack.entries }
        p.present()
        XCTAssertFalse(p.rows.isEmpty, "precondition: the empty list showed")

        p.query = "~/"

        XCTAssertTrue(
            p.rows.isEmpty, "the file rows are gone synchronously"
        )
    }

    // MARK: - The focus note

    func testTheNoteOutlivesDismissForTheViewToActOn() {
        let p = FilePickerPresenter()
        p.present()
        let responder = NSResponder()
        p.focus.priorResponder = responder

        p.dismiss()

        XCTAssertTrue(p.focus.priorResponder === responder)
    }

    func testRestoringReleasesTheNote() {
        let p = FilePickerPresenter()
        p.present()
        p.focus.priorResponder = NSResponder()

        p.restoreFocus()

        XCTAssertNil(p.focus.priorResponder)
    }

    // MARK: - Standing down

    func testTheKeyboardClaimFollowsPresentation() {
        let p = FilePickerPresenter.shared
        defer { p.dismiss() }

        XCTAssertFalse(FilePickerPresenter.isClaimingKeyboard)

        p.present()

        XCTAssertTrue(FilePickerPresenter.isClaimingKeyboard)
    }

    /// Registered in the one place every other monitor consults, which is what
    /// makes a new modal stand down everywhere at once.
    func testTheModalRegisterSeesAnOpenPicker() {
        let p = FilePickerPresenter.shared
        defer { p.dismiss() }

        XCTAssertFalse(GalacticModals.isClaimingKeyboard)

        p.present()

        XCTAssertTrue(GalacticModals.isClaimingKeyboard)
    }

    // MARK: - Keeping the index

    /// Poll rather than sleep a fixed time: the walk is a detached task and its
    /// duration is the filesystem's business, not this test's.
    @MainActor
    private func waitForIndex(_ presenter: FilePickerPresenter) async throws {
        for _ in 0..<400 {
            if presenter.indexedCount > 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the index never landed")
    }

    @discardableResult
    private func write(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// A half-million-file ceiling is only usable if the walk does not happen
    /// while a reader waits for a field, so a second open of the same root ranks
    /// against what is already held.
    @MainActor
    func testASecondOpenOfTheSameRootDoesNotClaimToBeIndexing() async throws {
        try write("a.swift")
        let presenter = FilePickerPresenter()
        presenter.rootProvider = { self.dir }

        presenter.present()
        try await waitForIndex(presenter)
        XCTAssertFalse(presenter.isIndexing)
        presenter.dismiss()

        presenter.present()

        XCTAssertFalse(presenter.isIndexing, "the tree is already walked")
        // The count is the bug this pins. Reopening used to adopt nothing and
        // report zero while the corpus sat in the cache untouched, which read as
        // the walk restarting.
        XCTAssertEqual(presenter.indexedCount, 1)
        XCTAssertEqual(
            presenter.rows.count, 0, "an empty query still offers history only"
        )
    }

    /// A finished tree is never re-walked, whatever the reader does next. The
    /// staleness window this replaced meant coming back to a root after ten
    /// minutes replaced a complete corpus with one counting up from zero.
    @MainActor
    func testAFinishedTreeIsNotWalkedAgainOnALaterOpen() async throws {
        try write("a.swift")
        let presenter = FilePickerPresenter()
        presenter.rootProvider = { self.dir }

        presenter.present()
        try await waitForIndex(presenter)
        presenter.dismiss()

        // A file appearing after the walk is deliberately not found: noticing
        // that is its own effort. What matters here is that nothing restarts.
        try write("b.swift")
        presenter.present()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(presenter.isIndexing)
        XCTAssertEqual(
            presenter.indexedCount, 1, "the corpus was kept, not rebuilt"
        )
    }

    /// Two opens must not become two enumerations. On a large root that was the
    /// difference between a picker that is slow once and one that is slow every
    /// time: each open added a walk, none had landed, so each looked like the
    /// first.
    @MainActor
    func testASecondOpenDoesNotStartASecondWalkOfTheSameTree() async throws {
        try write("a.swift")
        let presenter = FilePickerPresenter()
        var walks = 0
        presenter.rootProvider = {
            walks += 1
            return self.dir
        }

        presenter.present()
        presenter.dismiss()
        presenter.present()
        try await waitForIndex(presenter)

        // The provider is asked per open — that is by design — but only one walk
        // may be in flight for a root at a time.
        XCTAssertEqual(walks, 2)
        XCTAssertEqual(presenter.indexedCount, 1)
    }

    /// Coming back to a tree already walked is instant, because re-rooting is a
    /// return trip rather than a departure.
    @MainActor
    func testATreeWalkedEarlierIsStillHeldAfterVisitingAnother() async throws {
        try write("a.swift")
        let other = try sibling("other")
        try Data("x".utf8).write(to: other.appendingPathComponent("inner.rb"))

        let presenter = FilePickerPresenter()
        presenter.rootProvider = { self.dir }
        presenter.present()
        try await waitForIndex(presenter)
        presenter.dismiss()

        presenter.rootProvider = { other }
        presenter.present()
        try await waitForIndex(presenter)
        presenter.dismiss()

        presenter.rootProvider = { self.dir }
        presenter.present()

        XCTAssertFalse(
            presenter.isIndexing, "the first tree was kept, not re-walked"
        )
    }

    /// The held index is only good for the tree it was walked under. Ranking one
    /// keystroke against the tree just left would be worse than showing nothing,
    /// because nothing is obviously nothing.
    @MainActor
    func testADifferentRootHasNothingHeldForIt() async throws {
        try write("a.swift")
        let other = try sibling("unrelated")
        try Data("x".utf8).write(to: other.appendingPathComponent("inner.rb"))

        let presenter = FilePickerPresenter()
        presenter.rootProvider = { self.dir }
        presenter.present()
        try await waitForIndex(presenter)
        presenter.dismiss()

        presenter.rootProvider = { other }
        presenter.present()

        XCTAssertTrue(
            presenter.isIndexing, "a different root has nothing held for it"
        )
    }

    /// What the held index is for: a query answered from it without a walk.
    @MainActor
    func testAHeldIndexAnswersAQueryOnTheNextOpen() async throws {
        try write("user_model.swift")
        let presenter = FilePickerPresenter()
        presenter.rootProvider = { self.dir }
        presenter.present()
        try await waitForIndex(presenter)
        presenter.dismiss()

        presenter.present()
        presenter.query = "usermodel"
        // One turn for the filter task, which is off the main actor.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            presenter.rows.map(\.relativePath), ["user_model.swift"]
        )
    }

    // MARK: - Remembering where it was left

    private func opened(owner: String, root: URL) -> FilePickerPresenter {
        let p = FilePickerPresenter()
        p.rootProvider = { root }
        p.ownerProvider = { owner }
        p.present()
        return p
    }

    /// Reopening the picker is returning to a place, not starting over.
    func testReopeningRestoresTheModeAndTheQuery() {
        let p = opened(owner: "one", root: dir)
        p.selectMode(.browse)
        p.query = "create"
        p.dismiss()

        p.present()

        XCTAssertEqual(p.mode, .browse)
        XCTAssertEqual(p.query, "create")
    }

    /// Spin the main loop until a condition holds. Expanding reads a directory
    /// off the main actor, so a tree arrives over several passes rather than in
    /// the call that asked for it.
    private func settle(
        _ description: String, until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    /// **The whole point of the Browse tab.** The folders a reader opened are
    /// still open, and they are there on the pass that draws the panel rather
    /// than filling in afterwards — the directories that were read are restored
    /// with the expansion that needed them.
    func testReopeningRestoresTheExpandedFoldersAtOnce() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("app/models"),
            withIntermediateDirectories: true
        )
        let root = FilePaths.canonical(dir)
        let p = opened(owner: "one", root: dir)
        p.selectMode(.browse)

        settle("the root to be read") { p.treeRows.count > 1 }
        p.moveTreeSelection(by: 1)
        XCTAssertEqual(p.treeRows[p.treeSelectedIndex].path, root + "/app")
        p.expandSelectedTreeRow()
        settle("app to be read") { p.treeRows.count > 2 }

        p.dismiss()
        p.present()

        XCTAssertEqual(
            p.treeRows.map(\.path),
            [root, root + "/app", root + "/app/models"],
            "restored whole, without waiting to be read again"
        )
        XCTAssertEqual(
            p.treeRows[p.treeSelectedIndex].path, root + "/app",
            "and on the row it was left on"
        )
    }

    /// **The reported defect.** Opening restored the query and then ran the
    /// ranked-list refresh unconditionally — which begins by cancelling the
    /// running scan, so it killed the one the restored filter had just started.
    /// The field showed the query and the tree showed everything.
    func testReopeningReappliesARestoredFilter() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("app"),
            withIntermediateDirectories: true
        )
        _ = try write("app/userthing.rb")
        _ = try write("unrelated.md")

        let p = opened(owner: "one", root: dir)
        p.selectMode(.browse)
        // Typed while the walk is still going, which is the ordinary case and
        // used to leave the tree empty for good: the walk finishing refreshed
        // the ranked list instead of the tree.
        p.query = "userthing"
        settle("the filter to land") { p.treeRows.count > 1 }
        let filtered = p.treeRows.map(\.path)
        XCTAssertFalse(
            filtered.contains { $0.hasSuffix("unrelated.md") },
            "precondition: the filter is actually filtering"
        )

        p.dismiss()
        p.present()
        settle("the filter to be reapplied") { p.treeRows.count > 1 }

        XCTAssertEqual(p.treeRows.map(\.path), filtered)
        XCTAssertEqual(p.query, "userthing")
    }

    /// Scrolling a long way is not the same act as selecting, and coming back
    /// to the selection would undo the scroll a reader is asking to keep.
    func testReopeningAsksToScrollBackToWhereItWas() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("app"),
            withIntermediateDirectories: true
        )
        _ = try write("app/one.rb")
        let root = FilePaths.canonical(dir)

        let p = opened(owner: "one", root: dir)
        p.selectMode(.browse)
        settle("the root to be read") { p.treeRows.count > 1 }
        p.noteScrollTop(root + "/app", in: .browse)
        p.dismiss()

        p.present()
        settle("the scroll target to be claimed") { p.scrollTarget != nil }

        XCTAssertEqual(
            p.scrollTarget,
            .init(mode: .browse, id: root + "/app")
        )
        p.clearScrollTarget()
        XCTAssertNil(p.scrollTarget, "taken once, by whoever scrolled")
    }

    /// With nothing scrolled, the selection is the honest fallback — it is
    /// where the reader last acted.
    func testAReaderWhoNeverScrolledComesBackToTheirSelection() throws {
        _ = try write("only.rb")
        let root = FilePaths.canonical(dir)

        let p = opened(owner: "one", root: dir)
        p.selectMode(.browse)
        settle("the root to be read") { p.treeRows.count > 1 }
        p.moveTreeSelection(by: 1)
        let selected = p.treeRows[p.treeSelectedIndex].path
        p.dismiss()

        p.present()
        settle("the scroll target to be claimed") { p.scrollTarget != nil }

        XCTAssertEqual(p.scrollTarget, .init(mode: .browse, id: selected))
        XCTAssertNotEqual(selected, root)
    }

    /// Both tabs remember their own place, and the target says which list it is
    /// for — only one of them is on screen to act on it.
    func testTheRankedListRemembersItsOwnScrollPosition() throws {
        _ = try write("userthing.rb")
        // The canonical spelling, which is what a corpus row carries.
        let wanted = FilePaths.canonical(dir) + "/userthing.rb"

        let p = opened(owner: "one", root: dir)
        p.query = "userthing"
        settle("the scan to land") { !p.rows.isEmpty }
        p.noteScrollTop(wanted, in: .search)
        p.dismiss()

        p.present()
        settle("the scroll target to be claimed") { p.scrollTarget != nil }

        XCTAssertEqual(p.scrollTarget, .init(mode: .search, id: wanted))
    }

    /// One picker, one state per set — a session's tree is not another's.
    func testEachOwnerKeepsItsOwnState() {
        let p = FilePickerPresenter()
        var owner = "one"
        p.rootProvider = { self.dir }
        p.ownerProvider = { owner }

        p.present()
        p.selectMode(.browse)
        p.query = "first"
        p.dismiss()

        owner = "two"
        p.present()

        XCTAssertEqual(p.mode, .search, "a set nobody has opened starts fresh")
        XCTAssertEqual(p.query, "")

        p.dismiss()
        owner = "one"
        p.present()

        XCTAssertEqual(p.mode, .browse, "and the first set is still where it was")
        XCTAssertEqual(p.query, "first")
    }

    /// **The root decides whether there is anything to restore.** Every saved
    /// path is under the root it was saved against, so a host that has re-rooted
    /// since is being offered a tree of somewhere else.
    func testAChangedRootDiscardsTheSavedState() throws {
        let elsewhere = try sibling("rerooted")
        let p = FilePickerPresenter()
        var root = dir!
        p.rootProvider = { root }
        p.ownerProvider = { "one" }

        p.present()
        p.selectMode(.browse)
        p.query = "create"
        p.dismiss()

        root = elsewhere
        p.present()

        XCTAssertEqual(p.mode, .search)
        XCTAssertEqual(p.query, "", "nothing carried over to a different tree")
    }
}
