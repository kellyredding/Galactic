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
final class FileCorpusStoreOverlayCeilingTests: FileIndexIsolatedTestCase {

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
        await FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        await FileCorpusStore.shared.forgetAll()
        await FileIndexRefreshSweep.shared.stop()
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
            FileCorpusStore.shared.startIndexing(
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
        let slices = FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical)
        return FileMatcher.matches(in: slices, query: query, limit: 50)
            .map { slices[$0.slice].corpus.relativePath(at: $0.index) }
    }

    /// Wait for a coalesced rebuild to land.
    ///
    /// Yielding is not enough and never was: the deferred rebuild is queued on
    /// the store's own executor, so giving up this one proves nothing about
    /// whether that one has run.
    private func settle(untilFound query: String, reaches count: Int) async {
        for _ in 0..<60 where found(query).count != count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// How many times the store has said it deferred a rebuild.
    ///
    /// Read from the log the operator reads. The alternative was a counter kept
    /// only for this, duplicating a signal that already exists and is already
    /// the thing consulted when asking whether the ceiling ever engages in
    /// production — where the answer so far is that it does not.
    private func coalescedRebuildCount() -> Int {
        FileIndexLog.shared.drain()
        let url = FileIndexPaths.logsDirectory
            .appendingPathComponent("index.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n")
            .filter { $0.contains("event=delta-coalesced") }.count
    }

    // MARK: - Below the ceiling

    /// The guarantee the synchronous path exists for: told about a file, a
    /// caller reading immediately afterwards sees it.
    func testACreatedFileIsSearchableImmediatelyBelowTheCeiling() async throws {
        await indexRoot()
        let created = try touch("src/below_ceiling.swift")

        await FileCorpusStore.shared.noteCreated(
            [created.path], canonicalRoot: canonical
        )

        XCTAssertEqual(found("belowceiling"), ["src/below_ceiling.swift"])
    }

    // MARK: - Above the ceiling

    /// Past the ceiling the rebuild is deferred rather than run inline. This is
    /// the cost being bought, asserted so that it is a decision rather than a
    /// surprise.
    ///
    /// The deferral is asserted by the store saying it took it, not by the file
    /// being briefly unsearchable. "Not yet searchable" is true and stops being
    /// observable from outside: the rebuild is queued on the store's own
    /// executor, so by the time a caller has returned and read the published
    /// copy it may already have run. Asserting the absence therefore describes
    /// the scheduler rather than the policy, and it failed about one run in
    /// three while nothing was wrong. What a caller can rely on is convergence,
    /// which `testTheOverlayConvergesAfterCoalescing` covers.
    func testTheRebuildIsDeferredAboveTheCeiling() async throws {
        await indexRoot()
        FileCorpusStore.overlayRebuildCeiling = 1
        let before = coalescedRebuildCount()

        var paths: [String] = []
        for index in 0..<3 {
            paths.append(try touch("src/over_ceiling_\(index).swift").path)
        }
        await FileCorpusStore.shared.noteCreated(paths, canonicalRoot: canonical)

        XCTAssertEqual(
            FileIndexSnapshot.shared.pendingOverlayCount(
                forCanonicalRoot: canonical
            ),
            3,
            "the overlay did not take the entries"
        )
        XCTAssertGreaterThan(
            coalescedRebuildCount(), before,
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
        await FileCorpusStore.shared.noteCreated(paths, canonicalRoot: canonical)

        await settle(untilFound: "converged", reaches: 3)

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
            await FileCorpusStore.shared.noteCreated([path], canonicalRoot: canonical)
        }

        await settle(untilFound: "batched", reaches: 5)

        XCTAssertEqual(
            found("batched").count, 5,
            "coalescing dropped entries from batches after the first"
        )
    }
}
