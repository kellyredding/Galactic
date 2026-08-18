import XCTest

@testable import Galactic

/// The owner-keyed collection, exercised with both shapes it has to serve.
///
/// Assist Ant passes a constant and Galaxy will pass a session id, so the tests
/// use both — the point of building this before Galaxy needs it is that the
/// keyed case is not a later redesign, and a test that only ever used one key
/// would not have shown that.
final class FileSetsTests: XCTestCase {

    private func makeSets() -> FileSets {
        FileSets(defaultRoot: { owner in
            URL(fileURLWithPath: "/work/\(owner)")
        })
    }

    func testASetIsCreatedOnFirstAskAndReturnedAfterwards() {
        let sets = makeSets()

        let first = sets.set(forOwner: "default")
        let second = sets.set(forOwner: "default")

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.ownerID, "default")
    }

    /// The root is resolved per owner, which is what Galaxy's sessions need — a
    /// value captured once would give every session the first one's directory.
    func testEachOwnerGetsItsOwnRoot() {
        let sets = makeSets()

        XCTAssertEqual(sets.set(forOwner: "a").root.path, "/work/a")
        XCTAssertEqual(sets.set(forOwner: "b").root.path, "/work/b")
    }

    func testSetsForDifferentOwnersAreIndependent() throws {
        let sets = makeSets()
        let a = sets.set(forOwner: "a")
        let b = sets.set(forOwner: "b")

        a.changeRoot(to: URL(fileURLWithPath: "/elsewhere"))

        XCTAssertEqual(a.root.path, "/elsewhere")
        XCTAssertEqual(b.root.path, "/work/b")
    }

    /// Asking whether an owner has a set must not be a way to give it one — the
    /// quit-time check asks about every session in the window.
    func testAskingForAnExistingSetDoesNotCreateOne() {
        let sets = makeSets()

        XCTAssertNil(sets.existingSet(forOwner: "a"))
        XCTAssertTrue(sets.allSets.isEmpty)

        _ = sets.set(forOwner: "a")

        XCTAssertNotNil(sets.existingSet(forOwner: "a"))
        XCTAssertEqual(sets.allSets.count, 1)
    }

    func testDiscardingAnOwnerRemovesItsSet() {
        let sets = makeSets()
        _ = sets.set(forOwner: "a")

        sets.discard(ownerID: "a")

        XCTAssertNil(sets.existingSet(forOwner: "a"))
    }

    /// Quitting is the one moment every set has to be asked at once, because the
    /// notes are in memory and nowhere else.
    func testPendingNotesAreReportedAcrossEverySet() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-sets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("a.swift")
        try Data("one\n".utf8).write(to: url)

        let sets = FileSets(defaultRoot: { _ in dir })
        _ = sets.set(forOwner: "a")
        let b = sets.set(forOwner: "b")

        XCTAssertFalse(sets.hasPendingNotes)

        try b.open(url: url)
        b.addNote(
            filePath: url.path,
            startLine: 1,
            endLine: 1,
            lineContent: "one",
            content: "a note",
            createdAt: "2026-08-18T00:00:00Z"
        )

        XCTAssertTrue(sets.hasPendingNotes)

        b.clearNotes()

        XCTAssertFalse(sets.hasPendingNotes)
    }

    /// The quit prompt's two numbers. "How many files" means files carrying
    /// notes, not files open — which is why the set answers it rather than the
    /// host counting tabs.
    func testTheTallyCountsNotesAndTheFilesHoldingThem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-sets-tally-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.swift")
        let b = dir.appendingPathComponent("b.swift")
        let c = dir.appendingPathComponent("c.swift")
        for url in [a, b, c] { try Data("one\n".utf8).write(to: url) }

        let sets = FileSets(defaultRoot: { _ in dir })
        let set = sets.set(forOwner: "default")
        try set.open(url: a)
        try set.open(url: b)
        try set.open(url: c)

        func note(_ url: URL) {
            set.addNote(
                filePath: url.path, startLine: 1, endLine: 1,
                lineContent: "one", content: "n",
                createdAt: "2026-08-18T00:00:00Z"
            )
        }
        note(a)
        note(a)
        note(b)

        let tally = sets.pendingNoteTally

        XCTAssertEqual(tally.notes, 3)
        XCTAssertEqual(tally.files, 2, "c is open but carries nothing")
    }
}
