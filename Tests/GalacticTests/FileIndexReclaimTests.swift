import XCTest

@testable import Galactic

/// Shard directories that no root answers for.
///
/// A retired root keeps its files on purpose — the rows are what make them
/// reachable, and the root that noticed is the wrong place to decide what
/// another still needs. Deciding it against the whole index is this.
@MainActor
final class FileIndexReclaimTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-reclaim-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-reclaim-root-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        await FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        await FileCorpusStore.shared.forgetAll()
        FileIndexRefreshSweep.shared.stop()
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private var canonical: String { FilePaths.canonical(root) }

    private func indexRoot() async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.startIndexing(
                root: root,
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    func testADirectoryNoRootAnswersForIsReclaimed() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("a_file.swift"))
        await indexRoot()

        // What a retired root leaves behind: files, and no row naming them.
        let orphan = FileIndexPaths.indexDirectory
            .appendingPathComponent("2gfmm5jd2dkqr")
        try FileManager.default.createDirectory(
            at: orphan, withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: orphan.appendingPathComponent("abc-1.gfsi")
        )

        let reclaimed = await FileCorpusStore.shared
            .reclaimOrphanedShardDirectories()
        XCTAssertEqual(reclaimed, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "an unreachable directory was left on disk"
        )
    }

    /// And the live one is not touched, which is the whole risk here.
    func testTheDirectoryForALiveRootSurvives() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("a_file.swift"))
        await indexRoot()

        let live = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))

        await FileCorpusStore.shared.reclaimOrphanedShardDirectories()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: live.path),
            "the reclaim deleted the index it was protecting"
        )
        let slices = FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical)
        XCTAssertFalse(slices.isEmpty, "the live corpus went with it")
    }

    // MARK: - Stopping a root on purpose

    /// Both halves in one call, because either alone is a defect: rows without
    /// files answer with nothing, and files without rows are unreachable bytes.
    func testStoppingARootForgetsItAndReclaimsItsFiles() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("a_file.swift"))
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        XCTAssertTrue(catalog.roots().contains(canonical), "fixture not indexed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        await FileCorpusStore.shared.stopIndexing(canonicalRoot: canonical)

        XCTAssertFalse(
            catalog.roots().contains(canonical),
            "the root is still in the index"
        )
        XCTAssertTrue(
            catalog.shards(forRoot: canonical).isEmpty,
            "the shard rows outlived the root"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "the shard files were orphaned rather than reclaimed"
        )
    }

    /// And this process stops answering from it, or a picker already open keeps
    /// serving a tree the index no longer covers.
    func testStoppingARootUnmapsItHere() async throws {
        try Data("x".utf8).write(
            to: root.appendingPathComponent("findable_thing.swift")
        )
        await indexRoot()
        XCTAssertFalse(
            FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical).isEmpty,
            "fixture was not mapped"
        )

        await FileCorpusStore.shared.stopIndexing(canonicalRoot: canonical)

        XCTAssertTrue(
            FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical).isEmpty,
            "the corpus is still being served after the root was dropped"
        )
    }

    /// The catalog file and the lock live alongside the shard directories and
    /// are not directories, so they must be passed over rather than matched.
    func testTheCatalogAndLockAreNotMistakenForOrphans() async throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("a_file.swift"))
        await indexRoot()
        await FileCorpusStore.shared.reclaimOrphanedShardDirectories()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: FileIndexPaths.catalogFile.path),
            "the catalog was reclaimed"
        )
    }
}
