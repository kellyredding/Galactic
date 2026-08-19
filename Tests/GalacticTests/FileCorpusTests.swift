import XCTest

@testable import Galactic

/// The corpus is bytes, so these are assertions about bytes.
///
/// Front-coding and restart points are storage decisions, and the whole point
/// of a storage decision is that nothing above it can tell. Most of what
/// follows is therefore the same assertion from different angles: whatever
/// went in comes back out, in order, exactly.
final class FileCorpusTests: XCTestCase {

    private let root = "/tmp/corpus-root"

    private func corpus(
        _ paths: [String], directories: Set<String> = [], modified: Date? = nil
    ) -> FileCorpus {
        var writer = FileCorpusWriter()
        for path in paths {
            writer.add(
                relativePath: path,
                modified: modified,
                isDirectory: directories.contains(path)
            )
        }
        return writer.finish(root: root)
    }

    // MARK: - Round trip

    func testRoundTripsEveryPathInSortedOrder() {
        let paths = ["b/two.swift", "a/one.swift", "a/deep/three.swift"]
        let built = corpus(paths)

        XCTAssertEqual(built.entryCount, 3)
        XCTAssertEqual(
            (0..<built.entryCount).map { built.relativePath(at: $0) },
            ["a/deep/three.swift", "a/one.swift", "b/two.swift"]
        )
    }

    /// The case front-coding exists for, at a size that crosses restart points
    /// several times over — a bug in the shared-prefix arithmetic shows up as
    /// one entry inheriting bytes from the entry above it.
    func testRoundTripsAcrossManyRestartBlocks() {
        var paths: [String] = []
        for directory in 0..<40 {
            for file in 0..<40 {
                paths.append("pkg\(directory)/module\(file)/source_file.swift")
            }
        }
        let built = corpus(paths)
        XCTAssertEqual(built.entryCount, paths.count)
        XCTAssertGreaterThan(
            built.entryCount / FileCorpus.restartInterval, 20,
            "the fixture must span many restart blocks to be worth running"
        )
        XCTAssertEqual(
            (0..<built.entryCount).map { built.relativePath(at: $0) },
            paths.sorted()
        )
    }

    /// A path longer than 255 bytes cannot record its whole shared prefix in
    /// one byte, so the encoder caps it. The cap must cost bytes, never
    /// correctness.
    func testRoundTripsPathsLongerThanTheSharedPrefixCap() {
        let deep = (0..<40).map { "directory-number-\($0)" }.joined(separator: "/")
        let built = corpus([deep + "/first.txt", deep + "/second.txt"])
        XCTAssertEqual(built.relativePath(at: 0), deep + "/first.txt")
        XCTAssertEqual(built.relativePath(at: 1), deep + "/second.txt")
    }

    func testRoundTripsNonASCIIPaths() {
        let built = corpus(["notes/café.md", "notes/naïve.md", "notes/zebra.md"])
        XCTAssertEqual(built.relativePath(at: 0), "notes/café.md")
        XCTAssertEqual(built.relativePath(at: 1), "notes/naïve.md")
    }

    func testEmptyCorpusAnswersWithoutCrashing() {
        let built = corpus([])
        XCTAssertTrue(built.isEmpty)
        XCTAssertEqual(built.range(under: root + "/anything"), 0..<0)
    }

    // MARK: - Subtree ranges

    /// The property re-rooting depends on: a directory's contents are one
    /// contiguous run, so a subtree is a range rather than a second index.
    func testRangeUnderSubrootIsContiguousAndComplete() {
        let built = corpus([
            "apps/one.swift", "apps/nested/two.swift", "apps/nested/three.swift",
            "docs/readme.md", "zoo/last.txt",
        ])
        let range = built.range(under: root + "/apps")
        let found = range.map { built.relativePath(at: $0) }.sorted()

        XCTAssertEqual(
            found, ["apps/nested/three.swift", "apps/nested/two.swift", "apps/one.swift"]
        )
    }

    /// `project-other` is not inside `project`, and a string prefix test would
    /// say it was. `-` sorts before `/`, so this is the case that would slip
    /// through a naive bound.
    func testRangeUnderDoesNotMatchSiblingWithSharedPrefix() {
        let built = corpus([
            "project/inside.swift", "project-other/outside.swift",
            "projects/also-outside.swift",
        ])
        let found = built.range(under: root + "/project").map {
            built.relativePath(at: $0)
        }
        XCTAssertEqual(found, ["project/inside.swift"])
    }

    func testRangeUnderTheRootItselfIsEverything() {
        let built = corpus(["a.txt", "b/c.txt"])
        XCTAssertEqual(built.range(under: root), 0..<2)
    }

    func testRangeUnderAPathOutsideTheRootIsEmpty() {
        let built = corpus(["a.txt"])
        XCTAssertTrue(built.range(under: "/somewhere/else").isEmpty)
    }

    /// Binary search has to hold across restart boundaries, which is where an
    /// off-by-one in the block arithmetic would hide.
    func testRangeUnderIsExactAcrossRestartBoundaries() {
        var paths: [String] = []
        for index in 0..<500 { paths.append("aaa/file\(index).txt") }
        for index in 0..<500 { paths.append("bbb/file\(index).txt") }
        let built = corpus(paths)

        let range = built.range(under: root + "/bbb")
        XCTAssertEqual(range.count, 500)
        for index in range {
            XCTAssertTrue(built.relativePath(at: index).hasPrefix("bbb/"))
        }
    }

    // MARK: - Per-entry facts

    func testDirectoryBitsTrackTheirEntries() {
        let built = corpus(
            ["src", "src/main.swift", "docs"], directories: ["src", "docs"]
        )
        for index in 0..<built.entryCount {
            let path = built.relativePath(at: index)
            XCTAssertEqual(
                built.isDirectory(at: index), path == "src" || path == "docs",
                "\(path) reported the wrong kind"
            )
        }
    }

    func testModificationTimeSurvivesToDayResolution() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let built = corpus(["a.txt"], modified: when)
        XCTAssertEqual(
            built.modified(at: 0).timeIntervalSince1970,
            when.timeIntervalSince1970,
            accuracy: 86_400
        )
    }

    func testMissingModificationTimeDoesNotCrashOrWrap() {
        let built = corpus(["a.txt"], modified: nil)
        XCTAssertEqual(built.modifiedDays[0], 0)
    }
}
