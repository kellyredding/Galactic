import XCTest

@testable import Galactic

/// Removing a shard from the index, rather than rebuilding it.
///
/// The skip check applies when the walk descends into a directory, so it decides
/// what a shard contains and never whether the shard exists. A top-level
/// directory that becomes skipped therefore cannot be dealt with by marking it
/// dirty — that rewalks and rebuilds it.
@MainActor
final class FileIndexPruneTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-prune-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-prune-root-\(UUID().uuidString)")
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

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private func indexRoot(skipping list: Set<String>? = nil) async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.startIndexing(
                root: root, skipping: list,
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    private func found(_ query: String) -> [String] {
        let slices = FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical)
        return FileMatcher.matches(in: slices, query: query, limit: 50)
            .map { slices[$0.slice].corpus.relativePath(at: $0.index) }
    }

    private var shardFiles: [String] {
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
            ?? []
    }

    func testPruningTakesTheShardOutOfTheIndex() async throws {
        try touch("unwanted/inside_it.swift")
        try touch("wanted/keep_it.swift")
        await indexRoot()
        XCTAssertEqual(found("insideit"), ["unwanted/inside_it.swift"])

        let identifier = FileIndexPaths.rootIdentifier("unwanted")
        XCTAssertTrue(
            shardFiles.contains { $0.hasPrefix("\(identifier)-") },
            "fixture never produced a shard file"
        )

        let pruned = await FileCorpusStore.shared.prune(
            shard: "unwanted", canonicalRoot: canonical
        )
        XCTAssertTrue(pruned)

        let catalog = try XCTUnwrap(FileIndexCatalog())
        XCTAssertNil(
            catalog.shards(forRoot: canonical).first { $0.name == "unwanted" },
            "the catalog still lists a shard that was pruned"
        )
        XCTAssertFalse(
            shardFiles.contains { $0.hasPrefix("\(identifier)-") },
            "the shard files outlived the row"
        )
        XCTAssertTrue(
            found("insideit").isEmpty, "a pruned shard is still being searched"
        )
        XCTAssertEqual(
            found("keepit"), ["wanted/keep_it.swift"], "its neighbour went too"
        )
    }

    /// The point of pruning rather than rewalking: it has to stay gone once the
    /// list that excluded it is in force.
    func testAPrunedShardIsNotResurrectedByTheNextIndex() async throws {
        try touch("unwanted/inside_it.swift")
        try touch("wanted/keep_it.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.setSkipListEntry(name: "unwanted", skipped: true)
        await FileCorpusStore.shared.prune(shard: "unwanted", canonicalRoot: canonical)

        // A fresh process against the same index and the same stored list.
        await FileCorpusStore.shared.forgetAll()
        await indexRoot()

        XCTAssertNil(
            catalog.shards(forRoot: canonical).first { $0.name == "unwanted" },
            "the shard came back on the next index"
        )
        XCTAssertTrue(
            found("insideit").isEmpty,
            "a directory the index is told to skip is being searched again"
        )
    }

    /// The index puts itself right even when nothing pruned.
    ///
    /// Pruning is an action a process takes, and nothing guarantees it ran: an
    /// edit interrupted between storing the entry and pruning, or one made by an
    /// application that has since exited, leaves the row behind. Mapping is the
    /// one place every launch passes through.
    func testAStaleRowForASkippedDirectoryIsReconciledOnLoad() async throws {
        try touch("unwanted/inside_it.swift")
        try touch("wanted/keep_it.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        // The entry is stored and nothing prunes — the interrupted case.
        catalog.setSkipListEntry(name: "unwanted", skipped: true)
        XCTAssertNotNil(
            catalog.shards(forRoot: canonical).first { $0.name == "unwanted" },
            "fixture assumes the row is still there"
        )

        await FileCorpusStore.shared.forgetAll()
        await indexRoot()

        XCTAssertNil(
            catalog.shards(forRoot: canonical).first { $0.name == "unwanted" },
            "a row for a skipped directory survived a load"
        )
        XCTAssertTrue(found("insideit").isEmpty)
        XCTAssertEqual(found("keepit"), ["wanted/keep_it.swift"])
    }

    func testPruningRemovesEveryGenerationAndAnyStrayTemporaryFile() async throws {
        try touch("unwanted/one.swift")
        await indexRoot()
        // A second generation, plus the wreckage of a write that never renamed.
        await FileCorpusStore.shared.refresh(shard: "unwanted", canonicalRoot: canonical)
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        let identifier = FileIndexPaths.rootIdentifier("unwanted")
        try Data("junk".utf8).write(
            to: directory.appendingPathComponent("\(identifier)-9.gfsi.tmp")
        )

        await FileCorpusStore.shared.prune(shard: "unwanted", canonicalRoot: canonical)

        XCTAssertTrue(
            shardFiles.filter { $0.hasPrefix("\(identifier)-") }.isEmpty,
            "left behind: \(shardFiles.filter { $0.hasPrefix("\(identifier)-") })"
        )
    }

    func testPruningTheRootShardIsRefused() async throws {
        try touch("a_file.swift")
        await indexRoot()
        let prunedRoot = await FileCorpusStore.shared.prune(
            shard: "", canonicalRoot: canonical
        )
        XCTAssertFalse(
            prunedRoot,
            "the root's own shard is what names all the others"
        )
        XCTAssertEqual(found("afile"), ["a_file.swift"])
    }
}

extension FileIndexPruneTests {

    /// Two publishes of the same shard must not be able to share a temp file.
    ///
    /// The image header carries magic, version and length but no checksum, so
    /// two interleaved writes of equal length would validate clean and yield
    /// garbage paths. The writer lease prevents it — which was the problem: the
    /// whole guarantee rested on one lock with nothing behind it.
    func testTheTemporaryFileIsUniquePerProcessAndAttempt() throws {
        let corpus = FileCorpusBuilder.build(root: root)
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        let target = FileCorpusFile.url(
            shardDirectory: directory, shard: "probe", generation: 1
        )

        // Watch what the write leaves behind mid-flight by writing twice and
        // confirming neither name could have been the other's.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var seen: Set<String> = []
        for _ in 0..<4 {
            let before = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
                    ?? []
            )
            try FileCorpusFile.write(corpus, to: target)
            _ = before
            seen.insert(target.lastPathComponent)
        }
        // The published name is stable; that is the contract readers rely on.
        XCTAssertEqual(seen, ["probe-1.gfsi"])

        // And a stray temp from a crashed writer is reaped by the next publish
        // rather than accumulating.
        try Data("junk".utf8).write(
            to: directory.appendingPathComponent("probe-1.gfsi.999.DEAD.tmp")
        )
        FileCorpusFile.removeSupersededGenerations(
            shardDirectory: directory, shard: "probe", keeping: 1
        )
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))
            ?? []
        XCTAssertTrue(
            leftovers.filter { $0.hasSuffix(".tmp") }.isEmpty,
            "a temporary file from a dead writer was never reclaimed: \(leftovers)"
        )
    }
}
