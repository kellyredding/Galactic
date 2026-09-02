import XCTest

@testable import Galactic

/// Which shards a skip-list edit actually changes.
///
/// The naive answer is "all of them", and it is expensive in a way that lands on
/// the user: rewalking a home directory for one entry means asking about six
/// protected directories to discover that nothing moved. Both directions can be
/// answered exactly instead.
@MainActor
final class FileIndexEditScopeTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-scope-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-scope-root-\(UUID().uuidString)")
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

    /// The builder says which skipped names it met, so a later un-skip knows
    /// which shards it would change.
    func testTheWalkReportsWhichSkippedNamesItMet() throws {
        try touch("with_noise/node_modules/dep.js")
        try touch("with_noise/src/real.swift")
        try touch("clean/only_source.swift")

        let noisy = FileCorpusBuilder.buildShard(root: root, shard: "with_noise")
        XCTAssertTrue(
            noisy.encounteredSkips.contains("node_modules"),
            "the walk skipped a directory and did not say so"
        )

        let clean = FileCorpusBuilder.buildShard(root: root, shard: "clean")
        XCTAssertFalse(
            clean.encounteredSkips.contains("node_modules"),
            "a shard reported meeting something that is not in it"
        )
    }

    /// And the index remembers, so the question survives the process that walked.
    func testTheIndexRemembersWhichShardsMetASkippedName() async throws {
        try touch("with_noise/node_modules/dep.js")
        try touch("clean/only_source.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        XCTAssertEqual(
            catalog.shardsEncountering(skip: "node_modules", root: canonical),
            ["with_noise"],
            "un-skipping would have rewalked the wrong set of shards"
        )
        XCTAssertTrue(
            catalog.shardsEncountering(skip: "coverage", root: canonical).isEmpty,
            "a name nothing met came back as affecting something"
        )
    }

    /// The record follows the shard's contents rather than accumulating: a
    /// directory that goes away stops being a reason to rewalk.
    func testTheRecordIsReplacedRatherThanAddedTo() async throws {
        let dependency = try touch("with_noise/node_modules/dep.js")
        try touch("with_noise/src/real.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        XCTAssertEqual(
            catalog.shardsEncountering(skip: "node_modules", root: canonical),
            ["with_noise"]
        )

        try FileManager.default.removeItem(
            at: dependency.deletingLastPathComponent()
        )
        await FileCorpusStore.shared.refresh(
            shard: "with_noise", canonicalRoot: canonical
        )

        XCTAssertTrue(
            catalog.shardsEncountering(skip: "node_modules", root: canonical).isEmpty,
            "the shard is still recorded as meeting a directory that is gone"
        )
    }
}
