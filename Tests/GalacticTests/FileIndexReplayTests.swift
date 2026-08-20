import XCTest

@testable import Galactic

/// Answering a replay without reading every path in it.
///
/// Asking for history means being sent everything that happened while the
/// application was away, as fast as the file system can deliver it — measured
/// after half an hour away at 1,048 callbacks carrying 11,807 paths in nine
/// seconds. The coalescing latency governs live events and does nothing for
/// these, so the volume has to be answered rather than absorbed.
final class FileIndexReplayTests: XCTestCase {

    private let root = "/Users/someone"

    // MARK: - Reducing paths to the shards they name

    func testAPathReducesToItsTopLevelSubtree() {
        XCTAssertEqual(
            FileIndexWatcher.subtrees(
                of: ["\(root)/projects/deep/inside/a.swift"],
                underCanonical: root
            ),
            ["\(root)/projects"]
        )
    }

    /// The point of the whole exercise: many paths, few calls.
    func testManyPathsInOneSubtreeReduceToOne() {
        let paths = (0..<5_000).map { "\(root)/projects/kajabi/file\($0).rb" }
        XCTAssertEqual(
            FileIndexWatcher.subtrees(of: paths, underCanonical: root),
            ["\(root)/projects"]
        )
    }

    func testPathsAcrossSubtreesKeepOneEachAndNoMore() {
        let paths =
            (0..<100).map { "\(root)/projects/a\($0).rb" }
            + (0..<100).map { "\(root)/Sync/b\($0).md" }
            + (0..<100).map { "\(root)/.cache/c\($0)" }
        XCTAssertEqual(
            FileIndexWatcher.subtrees(of: paths, underCanonical: root),
            ["\(root)/projects", "\(root)/Sync", "\(root)/.cache"]
        )
    }

    /// An entry sitting directly in the root names itself, which is what
    /// `markSubtreeDirty` then reduces to a shard by the same rule. Reducing it
    /// further here would be this function deciding something the store already
    /// decides.
    func testAnEntryDirectlyInTheRootNamesItself() {
        XCTAssertEqual(
            FileIndexWatcher.subtrees(
                of: ["\(root)/.zshrc"], underCanonical: root
            ),
            ["\(root)/.zshrc"]
        )
    }

    /// The root path itself reduces to nothing, matching `markSubtreeDirty`,
    /// which drops it for the same reason: there is no relative entry to take a
    /// first component from. Asserted rather than left implicit, because the two
    /// have to agree — this function exists to do that reduction early, not
    /// differently.
    func testTheRootItselfIsDropped() {
        XCTAssertTrue(
            FileIndexWatcher.subtrees(of: [root], underCanonical: root).isEmpty
        )
    }

    /// The stream watches one root. Anything else arriving is not this index's
    /// to answer for, and guessing a subtree from it would mark a shard dirty
    /// that has nothing to do with the change.
    func testAPathOutsideTheRootIsDropped() {
        XCTAssertTrue(
            FileIndexWatcher.subtrees(
                of: ["/Volumes/elsewhere/thing.rb", "/etc/hosts"],
                underCanonical: root
            ).isEmpty
        )
    }

    func testNoPathsReduceToNothing() {
        XCTAssertTrue(
            FileIndexWatcher.subtrees(of: [], underCanonical: root).isEmpty
        )
    }

    // MARK: - The threshold itself

    /// Bounded against the cost this exists to avoid. The measurement recorded
    /// in the watcher is 213 ms per nine hundred paths of cold `lstat`, so the
    /// limit has to keep the read-each-path branch to a fraction of that
    /// however long the application was away.
    func testTheLimitKeepsTheExpensiveBranchShort() {
        XCTAssertLessThanOrEqual(
            FileIndexWatcher.replayPathLimit, 900,
            "above the measured 213 ms burst, the cheap branch is never taken "
                + "for the case it was written for"
        )
        XCTAssertGreaterThan(
            FileIndexWatcher.replayPathLimit, 0,
            "a limit of zero would rewalk subtrees for a single changed file"
        )
    }

    /// A replay that never announces its end must not buffer forever, so the
    /// grace timer has to be a real duration.
    func testTheGraceIsFiniteAndNotInstant() {
        XCTAssertGreaterThan(FileIndexWatcher.replayGrace, 0)
        XCTAssertLessThanOrEqual(FileIndexWatcher.replayGrace, 60)
    }
}
