import XCTest

@testable import Galactic

/// How often the overlay is re-encoded, rather than what it re-encodes to —
/// `FileCorpusTests` owns the latter.
///
/// Re-encoding the whole overlay per event batch is microseconds while the
/// overlay is a few hundred entries, and that is what makes a created file
/// searchable the instant something is told about it. Nothing enforced the
/// premise: a stale-cursor replay drove the overlay to 13,226 entries and one
/// dependency cache to 38,718, and at those sizes the per-batch rebuild held
/// the main actor for minutes and starved the sweep that would have drained
/// it. Past a ceiling the rebuild is deferred by one turn instead.
@MainActor
final class FileCorpusStoreOverlayCeilingTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-ceiling-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-ceiling-root-\(UUID().uuidString)")
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
        FileCorpusStore.overlayRebuildCeiling = 2_000
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

    private func found(_ query: String) -> [String] {
        let slices = FileCorpusStore.shared.slices(forCanonicalRoot: canonical)
        return FileMatcher.matches(in: slices, query: query, limit: 50)
            .map { slices[$0.slice].corpus.relativePath(at: $0.index) }
    }

    // MARK: - Below the ceiling

    /// The guarantee the synchronous path exists for: told about a file, a
    /// caller reading immediately afterwards sees it.
    func testACreatedFileIsSearchableImmediatelyBelowTheCeiling() async throws {
        await indexRoot()
        let created = try touch("src/below_ceiling.swift")

        FileCorpusStore.shared.noteCreated(
            [created.path], canonicalRoot: canonical
        )

        XCTAssertEqual(found("belowceiling"), ["src/below_ceiling.swift"])
    }

    // MARK: - Above the ceiling

    /// Past the ceiling the rebuild waits a turn, so the file is not yet
    /// searchable. This is the cost being bought, asserted so that it is a
    /// decision rather than a surprise.
    func testACreatedFileWaitsATurnAboveTheCeiling() async throws {
        await indexRoot()
        FileCorpusStore.overlayRebuildCeiling = 1

        var paths: [String] = []
        for index in 0..<3 {
            paths.append(try touch("src/over_ceiling_\(index).swift").path)
        }
        FileCorpusStore.shared.noteCreated(paths, canonicalRoot: canonical)

        XCTAssertEqual(
            FileCorpusStore.shared.pendingOverlayCount(
                forCanonicalRoot: canonical
            ),
            3,
            "the overlay did not take the entries"
        )
        XCTAssertTrue(
            found("overceiling").isEmpty,
            "the rebuild ran inline despite the overlay being over the ceiling"
        )
    }

    /// And the deferral converges: everything added while coalescing is there
    /// once the queued rebuild has run.
    func testTheOverlayConvergesAfterCoalescing() async throws {
        await indexRoot()
        FileCorpusStore.overlayRebuildCeiling = 1

        var paths: [String] = []
        for index in 0..<3 {
            paths.append(try touch("src/converged_\(index).swift").path)
        }
        FileCorpusStore.shared.noteCreated(paths, canonicalRoot: canonical)

        await Task.yield()

        XCTAssertEqual(
            found("converged").sorted(),
            [
                "src/converged_0.swift",
                "src/converged_1.swift",
                "src/converged_2.swift",
            ],
            "entries added while coalescing never made it into the delta"
        )
    }

    /// One rebuild per turn, not one per batch: a second batch arriving while
    /// a rebuild is already queued does not queue another.
    func testRepeatedBatchesCoalesceIntoOneRebuild() async throws {
        await indexRoot()
        FileCorpusStore.overlayRebuildCeiling = 1

        for index in 0..<5 {
            let path = try touch("src/batched_\(index).swift").path
            FileCorpusStore.shared.noteCreated([path], canonicalRoot: canonical)
        }

        await Task.yield()

        XCTAssertEqual(
            found("batched").count, 5,
            "coalescing dropped entries from batches after the first"
        )
    }
}
