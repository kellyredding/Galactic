import XCTest

@testable import Galactic

/// Carrying a shard's event position forward without walking it.
///
/// A root replays from the *oldest* position among its shards, and a position
/// only ever moved when a shard was published. A shard taken off the refresh
/// rotation is never published, so it froze — and dragged every launch's replay
/// further back than the last, measured at 550,799 paths from a day earlier.
@MainActor
final class FileIndexPositionTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-position-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-position-root-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        FileCorpusStore.shared.forgetAll()
        FileIndexRefreshSweep.shared.stop()
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private var canonical: String { FilePaths.canonical(root) }

    private func touch(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    private func indexRoot() async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.index(
                root: root, skipping: [],
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    private func position(of shard: String, in catalog: FileIndexCatalog)
        -> UInt64?
    {
        catalog.shards(forRoot: canonical)
            .first { $0.name == shard }?.eventsID
    }

    // MARK: - The catalog write

    func testAPositionMovesForward() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.record(
            root: canonical, name: "one", generation: 1, entryCount: 1,
            eventsUUID: "UUID", eventsID: 100
        )
        catalog.advanceEventPosition(
            root: canonical, name: "one", uuid: "UUID", id: 500
        )
        XCTAssertEqual(position(of: "one", in: catalog), 500)
    }

    /// Monotonic, and enforced in the write rather than by the caller: two
    /// applications may be doing this at once and the one with the older idea of
    /// now must not win.
    func testAPositionNeverMovesBackward() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.record(
            root: canonical, name: "one", generation: 1, entryCount: 1,
            eventsUUID: "UUID", eventsID: 900
        )
        catalog.advanceEventPosition(
            root: canonical, name: "one", uuid: "UUID", id: 100
        )
        XCTAssertEqual(position(of: "one", in: catalog), 900)
    }

    /// Only the position moves. A shard carried forward has not been read, so
    /// claiming a new generation for it would say the opposite.
    func testCarryingAShardForwardDoesNotTouchWhatItHolds() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.record(
            root: canonical, name: "one", generation: 7, entryCount: 42,
            eventsUUID: "UUID", eventsID: 100
        )
        catalog.advanceEventPosition(
            root: canonical, name: "one", uuid: "UUID", id: 500
        )
        let shard = try XCTUnwrap(
            catalog.shards(forRoot: canonical).first { $0.name == "one" }
        )
        XCTAssertEqual(shard.generation, 7)
        XCTAssertEqual(shard.entryCount, 42)
        XCTAssertFalse(shard.dirty)
    }

    // MARK: - Which shards get carried

    /// **The defect this exists for.** A shard frozen at an old position is the
    /// one that drags the whole root's replay backwards, and it is exactly the
    /// one nothing is going to publish.
    func testAFrozenShardIsCarriedForward() async throws {
        try touch("stale/a.swift")
        try touch("fresh/b.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.advanceEventPosition(
            root: canonical, name: "stale", uuid: "UUID", id: 1
        )
        // Reset to something ancient by rewriting the row outright, since the
        // advance above will not move a position backwards.
        catalog.record(
            root: canonical, name: "stale", generation: 1, entryCount: 1,
            eventsUUID: FileIndexWatcher.volumeUUID(for: canonical),
            eventsID: 1
        )
        XCTAssertEqual(position(of: "stale", in: catalog), 1)

        FileCorpusStore.shared.advanceUntouchedShards(
            canonicalRoot: canonical, to: 9_000
        )

        XCTAssertEqual(
            position(of: "stale", in: catalog), 9_000,
            "a shard nothing happened to is still reporting a day-old position"
        )
    }

    /// A shard the replay mentioned is owed a walk, and a walk is what will set
    /// its position. Carrying it forward here would claim it is current as of an
    /// event it has not read.
    func testAShardOwedAWalkIsLeftAlone() async throws {
        try touch("dirty/a.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.record(
            root: canonical, name: "dirty", generation: 1, entryCount: 1,
            eventsUUID: FileIndexWatcher.volumeUUID(for: canonical),
            eventsID: 1
        )
        catalog.markDirty(root: canonical, name: "dirty")

        FileCorpusStore.shared.advanceUntouchedShards(
            canonicalRoot: canonical, to: 9_000
        )

        XCTAssertEqual(
            position(of: "dirty", in: catalog), 1,
            "a shard owed a walk was declared current without being read"
        )
    }

    // MARK: - A shard owed a walk is still a shard

    /// **The regression this caught.** Marking a shard dirty says it is owed a
    /// walk, not that what it holds is unusable — and skipping it at load made
    /// the whole subtree unanswerable. The consequence was not a stale result: a
    /// picker asking for a subtree its covering root could no longer serve
    /// adopted it as a root of its own and walked four hundred thousand entries
    /// the index already held.
    ///
    /// Reached here through the replay path that exposed it, because a large
    /// replay is what marks a subtree dirty in the first place.
    func testADirtyShardIsStillMappedAtLoad() async throws {
        try touch("sub/findable_thing.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.markDirty(root: canonical, name: "sub")
        XCTAssertTrue(
            try XCTUnwrap(
                catalog.shards(forRoot: canonical).first { $0.name == "sub" }
            ).dirty,
            "fixture did not mark the shard"
        )

        // Drop everything held in memory and come back to it, which is what a
        // launch does.
        FileCorpusStore.shared.forgetAll()
        await indexRoot()

        let rows = FilePickerRanking.matches(
            FileCorpusStore.shared.slices(forCanonicalRoot: canonical),
            query: "findablething",
            relativeTo: canonical
        )
        XCTAssertEqual(
            rows.map(\.relativePath), ["sub/findable_thing.swift"],
            "a shard owed a walk answered with nothing, so whatever asked for "
                + "this subtree will index it a second time"
        )
    }

    // MARK: - What a top-level entry invalidates

    /// A file sitting directly in the root belongs to the root's own shard, not
    /// to one named after it. Taking the first path component gave the second
    /// answer, so a mark for such a file landed on a shard that does not exist
    /// and nothing was invalidated at all — which only showed up once a large
    /// replay started routing changes through this path instead of the overlay.
    func testAFileDirectlyInTheRootMarksTheRootShard() async throws {
        try touch("a.swift")
        try touch("sub/b.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        FileCorpusStore.shared.markSubtreeDirty(
            root.appendingPathComponent("a.swift").path,
            canonicalRoot: canonical, reason: "test"
        )

        let rootShard = try XCTUnwrap(
            catalog.shards(forRoot: canonical).first { $0.name.isEmpty }
        )
        XCTAssertTrue(
            rootShard.dirty,
            "a change directly in the root invalidated nothing"
        )
    }

    /// A path further down still names its own subtree and leaves the root
    /// alone, which is what stops every event in a tree rewalking the root.
    func testAPathInsideASubtreeLeavesTheRootAlone() async throws {
        try touch("sub/b.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        FileCorpusStore.shared.markSubtreeDirty(
            root.appendingPathComponent("sub/b.swift").path,
            canonicalRoot: canonical, reason: "test"
        )

        let rows = catalog.shards(forRoot: canonical)
        XCTAssertTrue(
            try XCTUnwrap(rows.first { $0.name == "sub" }).dirty,
            "the subtree that changed was not marked"
        )
        XCTAssertFalse(
            try XCTUnwrap(rows.first { $0.name.isEmpty }).dirty,
            "an event deep in a tree rewalks the root as well"
        )
    }

    /// The whole point, stated as the thing a launch actually reads: the oldest
    /// position across the root is what a replay starts from, and it has to rise.
    func testTheOldestPositionInTheRootRises() async throws {
        try touch("one/a.swift")
        try touch("two/b.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let uuid = FileIndexWatcher.volumeUUID(for: canonical)
        for name in ["one", "two"] {
            catalog.record(
                root: canonical, name: name, generation: 1, entryCount: 1,
                eventsUUID: uuid, eventsID: 5
            )
        }
        let before = catalog.shards(forRoot: canonical)
            .compactMap(\.eventsID).min()
        XCTAssertEqual(before, 5)

        FileCorpusStore.shared.advanceUntouchedShards(
            canonicalRoot: canonical, to: 9_000
        )

        let after = catalog.shards(forRoot: canonical)
            .compactMap(\.eventsID).min()
        XCTAssertEqual(
            after, 9_000,
            "the replay floor did not move, so the next launch replays from the "
                + "same place as this one"
        )
    }
}
