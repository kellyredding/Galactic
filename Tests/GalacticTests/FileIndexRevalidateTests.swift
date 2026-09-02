import XCTest

@testable import Galactic

/// A second application publishes; this one has to notice.
///
/// Replacement is safe by construction — a mapping names one immutable
/// generation and the inode outlives the unlink — and that is exactly why it is
/// invisible. Without asking, a process serves the generation it mapped at
/// launch for the rest of its life, and two applications answer the same query
/// differently.
@MainActor
final class FileIndexRevalidateTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-reval-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-reval-root-\(UUID().uuidString)")
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

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private func indexRoot() async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.index(
                root: root,
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    private func found(_ query: String) -> [String] {
        let slices = FileCorpusStore.shared.slices(forCanonicalRoot: canonical)
        return FileMatcher.matches(in: slices, query: query, limit: 50)
            .map { slices[$0.slice].corpus.relativePath(at: $0.index) }
    }

    /// Publish a shard the way another process would: write the file, record the
    /// row, and tell this store nothing.
    private func publishElsewhere(shard: String) throws -> UInt64 {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        let previous = catalog.shards(forRoot: canonical)
            .first { $0.name == shard }?.generation ?? 0
        let generation = previous + 1
        let corpus = FileCorpusBuilder.buildShard(root: root, shard: shard).corpus
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        try FileCorpusFile.write(
            corpus,
            to: FileCorpusFile.url(
                shardDirectory: directory,
                shard: FileIndexPaths.rootIdentifier(shard),
                generation: generation
            )
        )
        catalog.record(
            root: canonical, name: shard, generation: generation,
            entryCount: corpus.entryCount, walkStartedAt: Date(),
            eventsUUID: nil, eventsID: nil
        )
        return generation
    }

    func testANewGenerationIsPickedUpWhenTheRootIsAskedForAgain() async throws {
        try touch("subtree/first_file.swift")
        await indexRoot()
        XCTAssertEqual(found("firstfile"), ["subtree/first_file.swift"])

        // Another application indexes a file this process never saw.
        try touch("subtree/second_file.swift")
        _ = try publishElsewhere(shard: "subtree")

        XCTAssertTrue(
            found("secondfile").isEmpty,
            "the fixture published nothing, so the test proves nothing"
        )

        XCTAssertEqual(
            FileCorpusStore.shared.revalidate(canonicalRoot: canonical),
            ["subtree"]
        )
        XCTAssertEqual(
            found("secondfile"), ["subtree/second_file.swift"],
            "a newer generation was on disk and this process kept serving the old one"
        )
    }

    /// The hook that matters: opening the picker is what asks.
    func testOpeningTheRootAgainRevalidatesIt() async throws {
        try touch("subtree/first_file.swift")
        await indexRoot()

        try touch("subtree/second_file.swift")
        _ = try publishElsewhere(shard: "subtree")
        XCTAssertTrue(found("secondfile").isEmpty)

        // What the picker does on open: ask for the same root again.
        await indexRoot()

        XCTAssertEqual(
            found("secondfile"), ["subtree/second_file.swift"],
            "opening the picker did not bring the mapping up to date"
        )
    }

    func testThisProcessDoesNotRemapItsOwnPublish() async throws {
        try touch("subtree/first_file.swift")
        await indexRoot()

        await FileCorpusStore.shared.refresh(
            shard: "subtree", canonicalRoot: canonical
        )

        XCTAssertTrue(
            FileCorpusStore.shared.revalidate(canonicalRoot: canonical).isEmpty,
            "the store remapped a generation it had just written itself"
        )
    }

    /// A shard another application pruned has to leave this process too, or it
    /// keeps offering files from a directory the index has stopped covering.
    func testAShardPrunedElsewhereStopsBeingServed() async throws {
        try touch("doomed/inside_it.swift")
        try touch("kept/other.swift")
        await indexRoot()
        XCTAssertEqual(found("insideit"), ["doomed/inside_it.swift"])

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.remove(root: canonical, name: "doomed")

        XCTAssertEqual(
            FileCorpusStore.shared.revalidate(canonicalRoot: canonical), ["doomed"]
        )
        XCTAssertTrue(
            found("insideit").isEmpty,
            "a shard removed from the index is still being searched"
        )
        XCTAssertEqual(found("other"), ["kept/other.swift"])
    }

    /// Documented behaviour rather than an accident: removal bits are indices
    /// into the generation they were gathered against, so they cannot survive a
    /// remap and are dropped. A deletion this process saw, which the newer
    /// generation predates, therefore reappears until an event or a walk settles
    /// it — which is narrow, and much better than marking unrelated files
    /// deleted.
    func testRemovalBitsAreDroppedRatherThanCarriedAcrossAGeneration() async throws {
        let doomed = try touch("subtree/vanishing_file.swift")
        try touch("subtree/other_file.swift")
        await indexRoot()

        // Another application publishes while the file still exists.
        _ = try publishElsewhere(shard: "subtree")

        // This process then observes the deletion.
        try FileManager.default.removeItem(at: doomed)
        FileCorpusStore.shared.noteRemoved([doomed.path], canonicalRoot: canonical)
        XCTAssertTrue(found("vanishingfile").isEmpty)

        FileCorpusStore.shared.revalidate(canonicalRoot: canonical)

        XCTAssertEqual(
            found("vanishingfile"), ["subtree/vanishing_file.swift"],
            """
            the removal bitset was carried across a remap, which means it is \
            being applied to indices it was not gathered against
            """
        )
    }
}
