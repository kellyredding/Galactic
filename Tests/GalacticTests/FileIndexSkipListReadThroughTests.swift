import XCTest

@testable import Galactic

/// The skip list is read from the index, not remembered by the application.
///
/// A captured copy is how one application comes to walk a shared corpus under
/// rules another has already changed — and since nothing records which list
/// produced a shard, the disagreement is invisible as well as unbounded.
@MainActor
final class FileIndexSkipListReadThroughTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-jit-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-jit-root-\(UUID().uuidString)")
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

    /// Index without supplying a list, so the index's own answer is used.
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

    func testAStoredAdditionIsHonouredWithoutTheHostSayingAnything() async throws {
        try touch("keepme/wanted_file.swift")
        try touch("hideme/unwanted_file.swift")

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.setSkipListEntry(root: canonical, name: "hideme", skipped: true)

        await indexRoot()

        XCTAssertEqual(found("wantedfile"), ["keepme/wanted_file.swift"])
        XCTAssertTrue(
            found("unwantedfile").isEmpty,
            "a directory the index was told to skip was walked anyway"
        )
    }

    /// The delta can also take something *out* of the derived list, which is what
    /// makes it a delta rather than a replacement.
    func testAStoredRemovalUnskipsSomethingTheDefaultSkips() async throws {
        try touch("node_modules/library_file.swift")

        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        XCTAssertTrue(
            FileCorpusBuilder.defaultSkipList.contains("node_modules"),
            "fixture assumes the default skips this"
        )
        catalog.setSkipListEntry(
            root: canonical, name: "node_modules", skipped: false
        )

        await indexRoot()

        XCTAssertEqual(
            found("libraryfile"), ["node_modules/library_file.swift"],
            "a name the index was told not to skip was skipped anyway"
        )
    }

    /// The point of reading through: a change made after the root was indexed is
    /// picked up by the next walk, with nothing notified and no copy refreshed.
    ///
    /// Uses a nested directory deliberately. The skip check applies when the walk
    /// *descends* into a directory, so it governs what a shard contains — not
    /// whether the shard itself exists. Making an already-indexed top-level
    /// directory disappear is pruning, which belongs to whatever writes these
    /// entries rather than to reading them.
    func testAChangeAfterIndexingTakesEffectOnTheNextWalk() async throws {
        try touch("parent/nested/appears_later.swift")
        try touch("parent/kept/stays_put.swift")
        await indexRoot()
        XCTAssertEqual(
            found("appearslater"), ["parent/nested/appears_later.swift"]
        )

        // Another application edits the shared index.
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.setSkipListEntry(root: canonical, name: "nested", skipped: true)

        // No notification, no reload — just the next walk of the parent shard.
        await FileCorpusStore.shared.refresh(
            shard: "parent", canonicalRoot: canonical
        )

        XCTAssertTrue(
            found("appearslater").isEmpty,
            "the walk used a list captured when the root was first indexed"
        )
        XCTAssertEqual(
            found("staysput"), ["parent/kept/stays_put.swift"],
            "the rest of the shard went with it"
        )
    }

    func testAnExplicitListStillWinsForACallerThatSuppliesOne() async throws {
        try touch("node_modules/library_file.swift")
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
        XCTAssertEqual(
            found("libraryfile"), ["node_modules/library_file.swift"],
            "an explicitly unfiltered walk was filtered"
        )
    }
}
