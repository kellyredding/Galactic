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
        try super.tearDownWithError()
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

    /// Return on a path re-roots rather than opening a file, which is the whole
    /// reason one field can do both jobs.
    func testCommittingAPathChangesTheRoot() throws {
        let inner = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true
        )
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var changed: [URL] = []
        p.onChangeRoot = { changed.append($0) }
        p.present()

        p.query = inner.path
        p.commit()

        XCTAssertEqual(changed.map(\.lastPathComponent), ["inner"])
        XCTAssertEqual(p.root?.lastPathComponent, "inner")
        XCTAssertEqual(p.query, "", "and the field is cleared to search it")
    }

    func testCommittingAPathThatIsAFileDoesNotReRoot() throws {
        let file = dir.appendingPathComponent("a.rb")
        try Data("x".utf8).write(to: file)
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var changed = 0
        p.onChangeRoot = { _ in changed += 1 }
        p.present()

        p.query = file.path
        p.commit()

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(p.root, dir)
    }

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

    /// A path being typed is not a filter, so the corpus is not consulted and
    /// the reader is not shown a list that ignores what they are doing.
    func testAPathQueryListsNothing() {
        let p = FilePickerPresenter()
        p.rootProvider = { [dir] in dir }
        var stack = ClosedTabStack()
        stack.push(url: dir.appendingPathComponent("closed.rb"), row: 0)
        p.closedProvider = { stack.entries }
        p.present()
        XCTAssertFalse(p.rows.isEmpty, "precondition: the empty list showed")

        p.query = "~/"

        XCTAssertTrue(p.rows.isEmpty)
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
}
