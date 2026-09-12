import XCTest

@testable import Galactic

/// The owner-keyed collection, exercised with both shapes it has to serve.
///
/// Assist Ant passes a constant and Galaxy a session id, so the tests use both —
/// a test that only ever used one key would not show the keyed case works.
final class FileSetsTests: XCTestCase {

    private func makeSets() -> FileSets {
        FileSets(defaultRoot: { owner in
            URL(fileURLWithPath: "/work/\(owner)")
        })
    }

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func note(_ url: URL, in set: FileSet) {
        set.addNote(
            filePath: url.path, startLine: 1, endLine: 1,
            lineContent: "one", content: "n",
            createdAt: "2026-08-18T00:00:00Z"
        )
    }

    func testAGroupIsCreatedOnFirstAskAndReturnedAfterwards() {
        let sets = makeSets()

        let first = sets.group(forOwner: "default")
        let second = sets.group(forOwner: "default")

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.ownerID, "default")
        XCTAssertEqual(first.sets.count, 1)
        XCTAssertTrue(first.selected.isDefault)
    }

    /// The root is resolved per owner, which is what Galaxy's sessions need — a
    /// value captured once would give every session the first one's directory.
    func testEachOwnerGetsItsOwnRoot() {
        let sets = makeSets()

        XCTAssertEqual(
            sets.group(forOwner: "a").defaultSet.root.path, "/work/a"
        )
        XCTAssertEqual(
            sets.group(forOwner: "b").defaultSet.root.path, "/work/b"
        )
    }

    func testGroupsForDifferentOwnersAreIndependent() {
        let sets = makeSets()
        let a = sets.group(forOwner: "a").defaultSet
        let b = sets.group(forOwner: "b").defaultSet

        a.changeRoot(to: URL(fileURLWithPath: "/elsewhere"))

        XCTAssertEqual(a.root.path, "/elsewhere")
        XCTAssertEqual(b.root.path, "/work/b")
    }

    /// Presenter memory and search results are filed by set id, so two
    /// sessions' defaults must not share one.
    func testDefaultSetsOfDifferentOwnersHaveDifferentIds() {
        let sets = makeSets()

        XCTAssertNotEqual(
            sets.group(forOwner: "a").defaultSet.id,
            sets.group(forOwner: "b").defaultSet.id
        )
    }

    /// Asking whether an owner has sets must not be a way to give it some — the
    /// quit-time check asks about every session in the window.
    func testAskingForAnExistingGroupDoesNotCreateOne() {
        let sets = makeSets()

        XCTAssertNil(sets.existingGroup(forOwner: "a"))
        XCTAssertTrue(sets.allSets.isEmpty)

        _ = sets.group(forOwner: "a")

        XCTAssertNotNil(sets.existingGroup(forOwner: "a"))
        XCTAssertEqual(sets.allSets.count, 1)
    }

    func testEverySetOfEveryOwnerIsCounted() {
        let sets = makeSets()
        _ = sets.group(forOwner: "a").create(
            name: "auth", root: URL(fileURLWithPath: "/work/a")
        )
        _ = sets.group(forOwner: "b")

        XCTAssertEqual(sets.allSets.count, 3)
    }

    func testDiscardingAnOwnerRemovesItsSets() {
        let sets = makeSets()
        _ = sets.group(forOwner: "a")

        sets.discard(ownerID: "a")

        XCTAssertNil(sets.existingGroup(forOwner: "a"))
    }

    /// Quitting is the one moment every set has to be asked at once, because the
    /// notes are in memory and nowhere else — including sets not on screen.
    func testPendingNotesAreReportedAcrossEverySet() throws {
        let dir = try tempDir("file-sets-tests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.swift")
        try Data("one\n".utf8).write(to: url)

        let sets = FileSets(defaultRoot: { _ in dir })
        _ = sets.group(forOwner: "a")
        let auth = try sets.group(forOwner: "b")
            .create(name: "auth", root: dir).get()

        XCTAssertFalse(sets.hasPendingNotes)

        try auth.open(url: url)
        note(url, in: auth)

        XCTAssertTrue(sets.hasPendingNotes)

        auth.clearNotes()

        XCTAssertFalse(sets.hasPendingNotes)
    }

    /// The quit prompt's two numbers. "How many files" means files carrying
    /// notes, not files open.
    func testTheTallyCountsNotesAndTheFilesHoldingThem() throws {
        let dir = try tempDir("file-sets-tally")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.swift")
        let b = dir.appendingPathComponent("b.swift")
        let c = dir.appendingPathComponent("c.swift")
        for url in [a, b, c] { try Data("one\n".utf8).write(to: url) }

        let sets = FileSets(defaultRoot: { _ in dir })
        let set = sets.group(forOwner: "default").defaultSet
        try set.open(url: a)
        try set.open(url: b)
        try set.open(url: c)
        note(a, in: set)
        note(a, in: set)
        note(b, in: set)

        let tally = sets.pendingNoteTally

        XCTAssertEqual(tally.notes, 3)
        XCTAssertEqual(tally.files, 2, "c is open but carries nothing")
    }

    /// One file annotated in two sets is one file on disk.
    func testAFileAnnotatedInTwoSetsIsCountedOnce() throws {
        let dir = try tempDir("file-sets-shared-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.swift")
        try Data("one\n".utf8).write(to: url)

        let sets = FileSets(defaultRoot: { _ in dir })
        let group = sets.group(forOwner: "default")
        let auth = try group.create(name: "auth", root: dir).get()
        try group.defaultSet.open(url: url)
        try auth.open(url: url)
        note(url, in: group.defaultSet)
        note(url, in: auth)

        let tally = sets.pendingNoteTally

        XCTAssertEqual(tally.notes, 2)
        XCTAssertEqual(tally.files, 1)
    }
}
