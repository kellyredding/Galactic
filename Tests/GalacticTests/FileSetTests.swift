import XCTest

@testable import Galactic

/// What a set keeps agreeing about.
///
/// The strip, the closed stack, the note store and the frozen content are each
/// tested on their own elsewhere. What is tested here is the part no one of them
/// can be: that closing a tab does all three of the things closing a tab means,
/// that a file's content does not change under a reader who switched away and
/// came back, and that a restore rebuilds the arrangement rather than re-packing
/// it.
final class FileSetTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-set-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String, _ text: String = "one\ntwo\n") throws
        -> URL
    {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeSet() -> FileSet {
        FileSet(ownerID: "test", root: dir)
    }

    // MARK: - Opening

    func testANewSetIsEmpty() {
        let set = makeSet()

        XCTAssertTrue(set.isEmpty)
        XCTAssertNil(set.selectedTab)
        XCTAssertNil(set.selectedFile)
        XCTAssertEqual(set.root, dir)
        XCTAssertEqual(set.name, "Default")
    }

    func testOpeningFreezesTheContentAndSelectsTheTab() throws {
        let set = makeSet()
        let url = try write("a.swift", "let x = 1\n")

        let tab = try set.open(url: url)

        XCTAssertEqual(set.selectedTab?.id, tab.id)
        XCTAssertEqual(set.selectedFile?.content, "let x = 1\n")
        XCTAssertEqual(set.file(forPath: url.path)?.kind, .source)
        XCTAssertEqual(set.recentFiles.map(\.path), [url.path])
    }

    /// The whole render policy rests on this. A reader's notes quote what was
    /// read, so re-reading on a second open would replace the bytes they cite.
    func testOpeningAnAlreadyOpenFileDoesNotRereadIt() throws {
        let set = makeSet()
        let url = try write("a.swift", "before\n")
        let first = try set.open(url: url)

        try Data("after\n".utf8).write(to: url)
        let second = try set.open(url: url)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(set.selectedFile?.content, "before\n")
    }

    func testOpeningAFileThatIsNotTextThrowsRatherThanOpeningATab() throws {
        let set = makeSet()
        var bytes = Data("ELF".utf8)
        bytes.append(0)
        let url = dir.appendingPathComponent("a.bin")
        try bytes.write(to: url)

        XCTAssertThrowsError(try set.open(url: url)) { error in
            XCTAssertEqual(
                error as? ReaderFile.LoadFailure, .notText
            )
        }
        XCTAssertTrue(set.isEmpty)
        XCTAssertTrue(set.recentFiles.isEmpty)
    }

    /// Opening a file the reader closed earlier takes it out of the history.
    /// Left in, the picker would offer a file whose tab is on screen.
    func testOpeningAClosedFileRemovesItFromTheClosedStack() throws {
        let set = makeSet()
        let url = try write("a.swift")
        let tab = try set.open(url: url)
        set.close(id: tab.id)
        XCTAssertEqual(set.closedTabs.entries.count, 1)

        try set.open(url: url)

        XCTAssertTrue(set.closedTabs.isEmpty)
    }

    // MARK: - Closing

    /// Closing means three things, and a host that did two of them would keep a
    /// review alive on a file nobody has open.
    func testClosingStacksTheTabDropsItsNotesAndReleasesItsContent() throws {
        let set = makeSet()
        let url = try write("a.swift")
        let tab = try set.open(url: url)
        set.addNoteForTesting(path: url.path)
        XCTAssertEqual(set.totalNoteCount, 1)

        let entry = set.close(id: tab.id)

        XCTAssertEqual(entry?.url.path, url.path)
        XCTAssertEqual(entry?.row, 0)
        XCTAssertEqual(set.closedTabs.entries.first?.path, url.path)
        XCTAssertEqual(set.totalNoteCount, 0)
        XCTAssertNil(set.file(forPath: url.path))
        XCTAssertTrue(set.isEmpty)
    }

    func testClosingAnUnknownTabDoesNothing() throws {
        let set = makeSet()
        try set.open(url: try write("a.swift"))

        XCTAssertNil(set.close(id: UUID()))
        XCTAssertEqual(set.tabs.tabs.count, 1)
        XCTAssertTrue(set.closedTabs.isEmpty)
    }

    /// A closed file's notes are gone, so reopening it starts clean rather than
    /// resurrecting a review the reader ended.
    func testReopeningAClosedFileDoesNotBringItsNotesBack() throws {
        let set = makeSet()
        let url = try write("a.swift")
        let tab = try set.open(url: url)
        set.addNoteForTesting(path: url.path)
        set.close(id: tab.id)

        try set.open(url: url)

        XCTAssertEqual(set.noteCount(forPath: url.path), 0)
    }

    // MARK: - Reopening

    func testReopeningTheLastClosedFileReturnsItToItsRow() throws {
        let set = makeSet()
        let a = try set.open(url: try write("a.swift"))
        try set.open(url: try write("b.swift"))
        set.close(id: a.id)

        let reopened = try set.reopenLastClosed()

        XCTAssertEqual(reopened?.url.lastPathComponent, "a.swift")
        XCTAssertEqual(set.tabs.position(of: reopened!.id)?.row, 0)
        XCTAssertTrue(set.closedTabs.isEmpty)
        XCTAssertNotNil(set.file(forPath: reopened!.path))
    }

    func testReopeningWithAnEmptyStackReturnsNil() throws {
        let set = makeSet()

        XCTAssertNil(try set.reopenLastClosed())
    }

    /// A file deleted since it was closed throws — and does not go back onto the
    /// stack, or it would be the first thing offered again.
    func testReopeningAVanishedFileThrowsAndDoesNotRestackIt() throws {
        let set = makeSet()
        let url = try write("a.swift")
        let tab = try set.open(url: url)
        set.close(id: tab.id)
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try set.reopenLastClosed())
        XCTAssertTrue(set.closedTabs.isEmpty)
    }

    // MARK: - The root

    func testChangingTheRootKeepsOpenTabsOpen() throws {
        let set = makeSet()
        let url = try write("a.swift")
        try set.open(url: url)

        set.changeRoot(to: dir.appendingPathComponent("sub"))

        XCTAssertEqual(set.root.lastPathComponent, "sub")
        XCTAssertEqual(set.tabs.tabs.count, 1)
        XCTAssertNotNil(set.file(forPath: url.path))
    }

    // MARK: - Persistence

    func testOpenPathRowsReportTheArrangement() throws {
        let set = makeSet()
        let a = try set.open(url: try write("a.swift"))
        try set.open(url: try write("b.swift"))
        set.move(id: a.id, toRow: 0, at: 1)

        XCTAssertEqual(
            set.openPathRows.map { $0.map { ($0 as NSString).lastPathComponent }
            },
            [["b.swift", "a.swift"]]
        )
    }

    /// The reader's rows are the reader's. Restoring through `open` would honour
    /// the soft row limit and re-pack them, which is the same wrong answer as
    /// reflowing on close, arriving a restart later.
    func testRestoringRebuildsRowsRatherThanRepackingThem() throws {
        let a = try write("a.swift")
        let b = try write("b.swift")
        let c = try write("c.swift")
        let set = makeSet()

        let dropped = set.restore(
            openPathRows: [[a.path], [b.path, c.path]],
            selectedPath: c.path
        )

        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(set.tabs.rows.count, 2)
        XCTAssertEqual(set.tabs.rows[0].count, 1)
        XCTAssertEqual(set.tabs.rows[1].count, 2)
        XCTAssertEqual(set.selectedPath, c.path)
        XCTAssertNotNil(set.file(forPath: b.path))
    }

    /// Between two launches a file gets deleted or replaced by something binary.
    /// Neither is a reason to lose the other tabs.
    func testRestoringDropsWhatWillNotOpenAndKeepsTheRest() throws {
        let a = try write("a.swift")
        let set = makeSet()

        let dropped = set.restore(
            openPathRows: [[a.path, dir.appendingPathComponent("gone").path]]
        )

        XCTAssertEqual(
            dropped.map { ($0 as NSString).lastPathComponent }, ["gone"]
        )
        XCTAssertEqual(set.tabs.tabs.count, 1)
        XCTAssertEqual(set.selectedPath, a.path)
    }

    func testRestoringARowThatLosesEveryFileLeavesNoEmptyRow() throws {
        let a = try write("a.swift")
        let set = makeSet()

        set.restore(
            openPathRows: [
                [dir.appendingPathComponent("gone").path], [a.path],
            ]
        )

        XCTAssertEqual(set.tabs.rows.count, 1)
        XCTAssertEqual(set.tabs.rows[0].count, 1)
    }

    func testRestoringNothingLeavesAnEmptySet() {
        let set = makeSet()

        XCTAssertTrue(set.restore(openPathRows: []).isEmpty)
        XCTAssertTrue(set.isEmpty)
        XCTAssertNil(set.selectedPath)
    }

    // MARK: - History

    func testRecentFilesAreMostRecentFirstAndDeduped() throws {
        let set = makeSet()
        let a = try write("a.swift")
        let b = try write("b.swift")

        try set.open(url: a)
        try set.open(url: b)
        try set.open(url: a)

        XCTAssertEqual(
            set.recentFiles.map(\.lastPathComponent), ["a.swift", "b.swift"]
        )
    }

    /// A file with a tab on screen is not history to be offered back.
    func testPresentedRecentsExcludeOpenFiles() throws {
        let set = makeSet()
        let a = try write("a.swift")
        let b = try write("b.swift")
        try set.open(url: a)
        let bTab = try set.open(url: b)
        set.close(id: bTab.id)

        XCTAssertEqual(
            set.presentedRecents().map(\.lastPathComponent), ["b.swift"]
        )
    }

    /// The closed stack is not subtracted, and that is the decision: subtracting
    /// it would leave this always empty in-session, since being closed is the
    /// only way a file leaves the tabs. Which list shows a closed file is the
    /// picker's to answer.
    func testPresentedRecentsStillOfferAClosedFile() throws {
        let set = makeSet()
        let a = try write("a.swift")
        let tab = try set.open(url: a)
        set.close(id: tab.id)

        XCTAssertEqual(set.closedTabs.entries.count, 1)
        XCTAssertEqual(
            set.presentedRecents().map(\.lastPathComponent), ["a.swift"]
        )
    }

    func testPresentedRecentsRespectTheirLimit() throws {
        let set = makeSet()
        for i in 0..<5 {
            let url = try write("f\(i).swift")
            let tab = try set.open(url: url)
            set.close(id: tab.id)
        }

        XCTAssertEqual(set.presentedRecents(limit: 2).count, 2)
        XCTAssertEqual(
            set.presentedRecents(limit: 2).first?.lastPathComponent,
            "f4.swift"
        )
    }

    func testRecentFilesAreCapped() throws {
        let set = makeSet()
        for i in 0...FileSet.recentLimit {
            try set.open(url: try write("f\(i).swift"))
        }

        XCTAssertEqual(set.recentFiles.count, FileSet.recentLimit)
    }
    // MARK: - Notes

    /// A note is anchored to frozen content, so a path with no tab has nothing
    /// to anchor to. Refused rather than stored, since a stored one would be
    /// invisible and would still reach a review.
    func testANoteOnAFileThatIsNotOpenIsRefused() throws {
        let set = makeSet()

        let note = set.addNote(
            filePath: "/nowhere/a.swift",
            startLine: 1,
            endLine: 1,
            lineContent: "one",
            content: "a note",
            createdAt: "2026-08-18T00:00:00Z"
        )

        XCTAssertNil(note)
        XCTAssertEqual(set.totalNoteCount, 0)
    }

    func testClearingNotesEmptiesEveryFile() throws {
        let set = makeSet()
        let a = try write("a.swift")
        let b = try write("b.swift")
        try set.open(url: a)
        try set.open(url: b)
        set.addNoteForTesting(path: a.path)
        set.addNoteForTesting(path: b.path)

        set.clearNotes()

        XCTAssertEqual(set.totalNoteCount, 0)
    }
}

extension FileSet {
    /// One note on a file, for the tests that only care that there is one.
    @discardableResult
    fileprivate func addNoteForTesting(path: String) -> FileNote? {
        addNote(
            filePath: path,
            startLine: 1,
            endLine: 1,
            lineContent: "one",
            content: "a note",
            createdAt: "2026-08-18T00:00:00Z"
        )
    }
}
