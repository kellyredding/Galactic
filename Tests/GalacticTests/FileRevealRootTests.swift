import XCTest

@testable import Galactic

/// Where the browser gets rooted, and the one case where climbing is refused.
///
/// Pure string policy, so every case here is stated rather than staged — the
/// floor especially, which exists for a tree nobody would want to walk and is
/// therefore the one rule a filesystem test could not make visible.
final class FileRevealRootTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/kr")

    private func resolve(_ file: String, from current: String) -> String {
        FileRevealRoot.resolve(
            file: URL(fileURLWithPath: file),
            from: URL(fileURLWithPath: current),
            floor: home
        ).path
    }

    // MARK: - Staying put

    /// A root that already contains the file does not move at all. The reader
    /// keeps the tree they are looking at.
    func testARootContainingTheFileIsKept() {
        XCTAssertEqual(
            resolve("/Users/kr/work/app/a.swift", from: "/Users/kr/work"),
            "/Users/kr/work"
        )
    }

    /// A root outside the floor that already holds the file is still kept —
    /// the floor governs climbing, not staying put.
    func testARootOutsideTheFloorHoldingTheFileIsKept() {
        XCTAssertEqual(
            resolve("/tmp/scratch/a.swift", from: "/tmp/scratch"),
            "/tmp/scratch"
        )
    }

    // MARK: - Climbing

    func testARootIsClimbedUntilItContainsTheFile() {
        XCTAssertEqual(
            resolve("/Users/kr/work/other/a.swift", from: "/Users/kr/work/app"),
            "/Users/kr/work"
        )
    }

    /// Component-wise, so a sibling whose name merely begins with the root's
    /// does not read as inside it.
    func testASiblingSharingAPrefixIsNotContained() {
        XCTAssertEqual(
            resolve("/Users/kr/work-other/a.swift", from: "/Users/kr/work"),
            "/Users/kr"
        )
    }

    /// The floor itself is a legal answer, and a cheap one: it is already an
    /// adopted root that every project beneath it is served by.
    func testTheClimbMayReachTheFloor() {
        XCTAssertEqual(
            resolve("/Users/kr/notes/a.md", from: "/Users/kr/work/app"),
            "/Users/kr"
        )
    }

    // MARK: - The cliff

    /// **Left to climb, this pair shares only `/`** — a tree nobody browses,
    /// and the one root no existing corpus covers.
    func testAFileOutsideTheFloorFallsBackToItsOwnFolder() {
        XCTAssertEqual(
            resolve("/tmp/scratch/a.swift", from: "/Users/kr/work"),
            "/tmp/scratch"
        )
    }

    /// And the mirror: a root outside the floor, reaching for a file inside it.
    /// Reached when the agent has moved the session somewhere like `/tmp`.
    func testARootOutsideTheFloorAlsoFallsBack() {
        XCTAssertEqual(
            resolve("/Users/kr/work/a.swift", from: "/tmp/scratch"),
            "/Users/kr/work"
        )
    }

    /// A volume of its own shares nothing but the separator.
    func testAFileOnAnotherVolumeFallsBack() {
        XCTAssertEqual(
            resolve("/Volumes/Backup/notes/a.md", from: "/Users/kr/work"),
            "/Volumes/Backup/notes"
        )
    }
}
