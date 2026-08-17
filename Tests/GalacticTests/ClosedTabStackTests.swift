import XCTest

@testable import Galactic

/// The set's history of what it has had open.
///
/// Uncapped in storage and capped only where it is shown, because this is what
/// the empty strip and the empty picker offer — a reader who closed something an
/// hour ago is precisely who comes looking for it.
final class ClosedTabStackTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/work/\(name)")
    }

    func testANewStackIsEmpty() {
        let s = ClosedTabStack()
        XCTAssertTrue(s.isEmpty)
        XCTAssertTrue(s.presented().isEmpty)
    }

    func testMostRecentlyClosedComesFirst() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)
        s.push(url: url("b.swift"), row: 0)

        XCTAssertEqual(s.entries.map(\.path), ["/work/b.swift", "/work/a.swift"])
    }

    func testPopTakesTheMostRecent() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)
        s.push(url: url("b.swift"), row: 1)

        let popped = s.pop()

        XCTAssertEqual(popped?.path, "/work/b.swift")
        XCTAssertEqual(popped?.row, 1, "and the row it wants to go back to")
        XCTAssertEqual(s.entries.count, 1)
    }

    func testPoppingAnEmptyStackIsNil() {
        var s = ClosedTabStack()
        XCTAssertNil(s.pop())
    }

    /// A history listing the same file four times is one a reader has to read
    /// past rather than one they can use.
    func testClosingTheSameFileTwiceIsOneEntry() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)
        s.push(url: url("b.swift"), row: 0)
        s.push(url: url("a.swift"), row: 0)

        XCTAssertEqual(s.entries.count, 2)
        XCTAssertEqual(
            s.entries.first?.path, "/work/a.swift",
            "and it moves to the front, because that is when it last happened"
        )
    }

    /// The newest row wins, since it is where the reader last had the file.
    func testARepeatedCloseTakesTheNewerRow() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)
        s.push(url: url("a.swift"), row: 2)

        XCTAssertEqual(s.entries.first?.row, 2)
    }

    /// Reopened from the picker rather than from the stack, so the entry has to
    /// go — otherwise the history claims a file is closed while its tab is on
    /// screen.
    func testRemovingDropsAnEntryReopenedAnotherWay() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)
        s.push(url: url("b.swift"), row: 0)

        s.remove(url: url("a.swift"))

        XCTAssertEqual(s.entries.map(\.path), ["/work/b.swift"])
    }

    func testRemovingSomethingAbsentIsHarmless() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)

        s.remove(url: url("never-open.swift"))

        XCTAssertEqual(s.entries.count, 1)
    }

    /// Storage keeps everything; only the window is capped.
    func testStorageIsUncappedAndPresentationIsNot() {
        var s = ClosedTabStack()
        for i in 0..<50 { s.push(url: url("f\(i).swift"), row: 0) }

        XCTAssertEqual(s.entries.count, 50)
        XCTAssertEqual(s.presented(limit: 20).count, 20)
        XCTAssertEqual(
            s.presented(limit: 20).first?.path, "/work/f49.swift",
            "the window is the newest end of the history"
        )
    }

    func testAZeroOrNegativeLimitShowsNothing() {
        var s = ClosedTabStack()
        s.push(url: url("a.swift"), row: 0)

        XCTAssertTrue(s.presented(limit: 0).isEmpty)
        XCTAssertTrue(s.presented(limit: -5).isEmpty)
    }
}
