import XCTest

@testable import Galactic

/// A directory the walk is not allowed to open.
///
/// The walk produces an empty corpus whether a directory is empty or refused,
/// which made the two indistinguishable — and publishing the second over a
/// populated shard replaces a working index with nothing and reports success.
/// Exercised with real permissions rather than a stub, because the whole point
/// is what `open` actually returns.
@MainActor
final class FileIndexRefusedWalkTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-refused-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-refused-root-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        // Readable again, or the directory cannot be deleted.
        for name in ["locked", "sub/locked"] {
            let path = root.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                chmod(path, 0o700)
            }
        }
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
                root: root, skipping: [],
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    // MARK: - The builder tells the difference

    func testARefusedTopDirectoryIsReportedRatherThanLookingEmpty() throws {
        try touch("locked/secret.swift")
        let locked = root.appendingPathComponent("locked")
        XCTAssertEqual(chmod(locked.path, 0o000), 0, "fixture did not apply")

        let walked = FileCorpusBuilder.buildShard(
            root: root, shard: "locked", skipping: []
        )

        XCTAssertTrue(
            walked.rootWasRefused,
            "a directory that could not be opened was reported as ordinary"
        )
        XCTAssertEqual(
            walked.corpus.entryCount, 0,
            "the corpus is empty either way — which is exactly the problem"
        )
    }

    /// An empty directory must not be mistaken for a refused one, or the store
    /// would decline to publish shards that are legitimately empty.
    func testAnEmptyDirectoryIsNotReportedAsRefused() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"),
            withIntermediateDirectories: true
        )
        let walked = FileCorpusBuilder.buildShard(
            root: root, shard: "empty", skipping: []
        )
        XCTAssertFalse(walked.rootWasRefused)
        XCTAssertEqual(walked.corpus.entryCount, 0)
    }

    // MARK: - The store refuses to publish nothing over something

    func testARefusedRewalkDoesNotReplaceAGoodShard() async throws {
        try touch("locked/one.swift")
        try touch("locked/two.swift")
        try touch("elsewhere/other.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let before = try XCTUnwrap(
            catalog.shards(forRoot: canonical).first { $0.name == "locked" }
        )
        XCTAssertEqual(before.entryCount, 2, "fixture was not indexed")

        // Permission goes away, then the shard is rewalked.
        let locked = root.appendingPathComponent("locked")
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        await FileCorpusStore.shared.refresh(shard: "locked", canonicalRoot: canonical)

        let after = try XCTUnwrap(
            catalog.shards(forRoot: canonical).first { $0.name == "locked" }
        )
        XCTAssertEqual(
            after.entryCount, 2,
            "a refused walk published an empty shard over a populated one"
        )
        XCTAssertEqual(
            after.generation, before.generation,
            "a refused walk published a new generation"
        )
        XCTAssertGreaterThan(
            after.walkedAt, before.walkedAt,
            "the attempt was not recorded, so the sweep will retry it every tick"
        )
        XCTAssertFalse(
            after.dirty,
            "a refused shard left dirty jumps the sweep queue forever"
        )
    }

    /// And what is already mapped stays mapped, so searches keep working.
    func testARefusedRewalkLeavesSearchResultsIntact() async throws {
        try touch("locked/findable_thing.swift")
        await indexRoot()

        let locked = root.appendingPathComponent("locked")
        XCTAssertEqual(chmod(locked.path, 0o000), 0)
        await FileCorpusStore.shared.refresh(shard: "locked", canonicalRoot: canonical)

        let slices = FileCorpusStore.shared.slices(forCanonicalRoot: canonical)
        let rows = FilePickerRanking.matches(
            slices, query: "findablething", relativeTo: canonical
        )
        XCTAssertEqual(
            rows.map(\.relativePath), ["locked/findable_thing.swift"],
            "a refused rewalk emptied the corpus this process was serving"
        )
    }
}
