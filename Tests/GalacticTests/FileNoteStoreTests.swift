import XCTest

@testable import Galactic

/// What the note store keeps, and what it lets go of.
///
/// The lifetime is the feature: these notes exist while files are open and are
/// gone on send, on delete, and on a tab closing. So the interesting assertions
/// are all about what disappears, and about the one thing that must *not* —
/// closing a file and opening it again is normal, and must be neither a way to
/// lose a note nor a way to end up with two.
final class FileNoteStoreTests: XCTestCase {

    private let stamp = "2026-08-17T14:00:00Z"

    private func store(
        _ entries: [(path: String, start: Int32, end: Int32, body: String)]
    ) -> FileNoteStore {
        var s = FileNoteStore()
        for e in entries {
            s.add(
                filePath: e.path, startLine: e.start, endLine: e.end,
                lineContent: "line \(e.start)", content: e.body,
                createdAt: stamp
            )
        }
        return s
    }

    // MARK: - Counting

    func testTotalCountSpansEveryFile() {
        let s = store([
            ("/a.swift", 1, 1, "one"),
            ("/a.swift", 5, 6, "two"),
            ("/b.swift", 2, 2, "three"),
        ])

        XCTAssertEqual(s.totalCount, 3)
        XCTAssertEqual(s.count(forPath: "/a.swift"), 2)
        XCTAssertEqual(s.count(forPath: "/b.swift"), 1)
        XCTAssertEqual(s.count(forPath: "/never-opened.swift"), 0)
    }

    /// The send bar counts the review, not the file on screen — a reader who
    /// annotated three files and is looking at a fourth still has all of it.
    func testAnEmptyStoreCountsNothing() {
        XCTAssertEqual(FileNoteStore().totalCount, 0)
        XCTAssertTrue(FileNoteStore().annotatedPaths.isEmpty)
    }

    // MARK: - Numbering

    /// Per file and monotonic, so two files each start at one.
    func testNumberingIsPerFile() {
        let s = store([
            ("/a.swift", 1, 1, "one"),
            ("/b.swift", 1, 1, "other file"),
            ("/a.swift", 9, 9, "two"),
        ])

        XCTAssertEqual(s.notes(forPath: "/a.swift").map(\.number), [1, 2])
        XCTAssertEqual(s.notes(forPath: "/b.swift").map(\.number), [1])
    }

    /// Identifiers are unique across the whole store, unlike numbers — the page
    /// addresses a note by number within one document, and the host addresses
    /// it by identifier without knowing which file it came from.
    func testIdentifiersAreUniqueAcrossFiles() {
        let s = store([
            ("/a.swift", 1, 1, "one"),
            ("/b.swift", 1, 1, "two"),
        ])
        let ids = s.notesByPath.values.flatMap { $0 }.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// A number is not reused when the note holding it is deleted. Reusing one
    /// would put two cards with the same identity on a page that is still open.
    func testANumberIsNotReusedAfterADelete() {
        var s = store([("/a.swift", 1, 1, "one")])
        let first = s.notes(forPath: "/a.swift")[0]

        s.delete(id: first.id)
        s.add(
            filePath: "/a.swift", startLine: 2, endLine: 2,
            lineContent: "line 2", content: "two", createdAt: stamp
        )

        XCTAssertEqual(s.notes(forPath: "/a.swift").map(\.number), [2])
    }

    // MARK: - Ordering

    /// Document order — where a note ends, then where it starts. The
    /// scrollback's comparator, so both surfaces agree about what "first"
    /// means.
    func testNotesComeBackInDocumentOrder() {
        let s = store([
            ("/a.swift", 40, 48, "later"),
            ("/a.swift", 2, 2, "first"),
            ("/a.swift", 10, 12, "middle"),
        ])

        XCTAssertEqual(
            s.notes(forPath: "/a.swift").map(\.content),
            ["first", "middle", "later"]
        )
    }

    func testTwoNotesEndingOnTheSameLineOrderByTheirStart() {
        let s = store([
            ("/a.swift", 8, 10, "wider"),
            ("/a.swift", 10, 10, "narrower"),
        ])

        XCTAssertEqual(
            s.notes(forPath: "/a.swift").map(\.content),
            ["wider", "narrower"]
        )
    }

    // MARK: - Editing

    func testUpdatingChangesOnlyThatNote() {
        var s = store([
            ("/a.swift", 1, 1, "one"),
            ("/a.swift", 2, 2, "two"),
        ])
        let target = s.notes(forPath: "/a.swift")[0]

        s.update(id: target.id, content: "edited")

        XCTAssertEqual(
            s.notes(forPath: "/a.swift").map(\.content), ["edited", "two"]
        )
    }

    func testUpdatingAnUnknownNoteDoesNothing() {
        var s = store([("/a.swift", 1, 1, "one")])

        s.update(id: 9999, content: "nope")

        XCTAssertEqual(s.notes(forPath: "/a.swift").map(\.content), ["one"])
    }

    func testDeletingTheLastNoteForAFileLeavesNoEntry() {
        var s = store([("/a.swift", 1, 1, "one")])
        let only = s.notes(forPath: "/a.swift")[0]

        s.delete(id: only.id)

        XCTAssertEqual(s.totalCount, 0)
        XCTAssertTrue(
            s.annotatedPaths.isEmpty,
            "an emptied file leaves no key behind, so a tab badge reads zero "
                + "rather than reading an empty array"
        )
    }

    // MARK: - Letting go

    /// A tab closed takes its file's notes and nothing else.
    func testDroppingAPathLeavesEveryOtherFileAlone() {
        var s = store([
            ("/a.swift", 1, 1, "one"),
            ("/b.swift", 1, 1, "keep me"),
        ])

        s.drop(path: "/a.swift")

        XCTAssertEqual(s.totalCount, 1)
        XCTAssertEqual(s.notes(forPath: "/b.swift").map(\.content), ["keep me"])
    }

    /// Numbering resets with the notes, which is what a reader who closed the
    /// file expects. Nothing downstream depends on it — the composer renumbers
    /// positionally across the whole review.
    func testAFileReopenedAfterDropStartsNumberingAgain() {
        var s = store([
            ("/a.swift", 1, 1, "one"),
            ("/a.swift", 2, 2, "two"),
        ])

        s.drop(path: "/a.swift")
        s.add(
            filePath: "/a.swift", startLine: 3, endLine: 3,
            lineContent: "line 3", content: "fresh", createdAt: stamp
        )

        XCTAssertEqual(s.notes(forPath: "/a.swift").map(\.number), [1])
    }

    /// The one thing that must not happen. The store is keyed by path, so a
    /// tab is a view onto it rather than the owner — switching away and back
    /// without closing keeps everything.
    func testNotesSurviveEverythingShortOfAnExplicitDrop() {
        let s = store([("/a.swift", 1, 1, "still here")])

        // No drop, no clear — the tab was merely switched away from.
        XCTAssertEqual(s.count(forPath: "/a.swift"), 1)
        XCTAssertEqual(
            s.notes(forPath: "/a.swift")[0].lineContent, "line 1",
            "and the quoted content is what it was when written"
        )
    }

    func testClearEmptiesEverything() {
        var s = store([
            ("/a.swift", 1, 1, "one"),
            ("/b.swift", 1, 1, "two"),
        ])

        s.clear()

        XCTAssertEqual(s.totalCount, 0)
        XCTAssertTrue(s.annotatedPaths.isEmpty)
    }

    /// After a send, the next note starts from one — the review that carried
    /// the old numbers is gone, so nothing is left to collide with.
    func testNumberingRestartsAfterClear() {
        var s = store([("/a.swift", 1, 1, "one")])

        s.clear()
        s.add(
            filePath: "/a.swift", startLine: 5, endLine: 5,
            lineContent: "line 5", content: "next review", createdAt: stamp
        )

        XCTAssertEqual(s.notes(forPath: "/a.swift").map(\.number), [1])
    }

    // MARK: - The reader seam

    /// The reason no new annotation surface was needed: a note is already the
    /// shape a reader reads, so an in-memory array serves where a database did.
    func testANoteIsAReaderAnnotation() {
        let s = store([("/a.swift", 4, 8, "why here")])
        let note: any ReaderAnnotation = s.notes(forPath: "/a.swift")[0]

        XCTAssertEqual(note.anchorType, .lineRange)
        XCTAssertEqual(note.anchorStartLine, 4)
        XCTAssertEqual(note.anchorEndLine, 8)
        XCTAssertEqual(note.anchorLineContent, "line 4")
        XCTAssertEqual(note.content, "why here")
        XCTAssertFalse(
            note.isStale,
            "content is frozen at open, so the document cannot move under the "
                + "anchor — whether the file moved is asked once, at send"
        )
        XCTAssertNil(
            note.anchorStartRow, "a line-only store declares nothing else"
        )
        XCTAssertNil(note.reviewNumber, "there is no review to belong to")
    }

    /// Anchoring screens on the anchor type a renderer accepts, so a note has
    /// to pass the source reader's screen or it would never be drawn.
    func testANoteSurvivesTheSourceReadersScreen() {
        let s = store([("/a.swift", 1, 1, "one")])
        let notes: [any ReaderAnnotation] = s.notes(forPath: "/a.swift")

        XCTAssertEqual(SourceRenderer.anchoring.screen(notes).count, 1)
    }
}
