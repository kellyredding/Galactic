import XCTest

@testable import Galactic

/// How often a walk in progress reports, rather than what it reports.
///
/// The builder reports once for every directory it enters. That is the right
/// contract for a synchronous consumer and the wrong cost for this one: each
/// report leaves the walking thread for the store and again for the main actor,
/// and the tree this runs against in earnest holds tens of thousands of
/// directories. What consumes the number is a label.
@MainActor
final class FileIndexProgressTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    /// Enough directories that a per-directory report is clearly visible
    /// against a clock-driven one, in one shard so a single walk covers them.
    private let directories = 400

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-progress-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-progress-root-\(UUID().uuidString)")
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
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private var canonical: String { FilePaths.canonical(root) }

    /// One shard holding `directories` subdirectories, each with a file in it.
    private func buildTree() throws {
        for index in 0..<directories {
            let directory = root
                .appendingPathComponent("deep")
                .appendingPathComponent(String(format: "d%04d", index))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data("x".utf8).write(
                to: directory.appendingPathComponent("file.swift")
            )
        }
    }

    func testProgressIsReportedOnAClockRatherThanPerDirectory() async throws {
        try buildTree()

        let counter = Counter()
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.startIndexing(
                root: root, skipping: [],
                onProgress: { _ in counter.increment() },
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }

        // A report per directory would be at least `directories`. The clock
        // runs at a tenth of a second and this tree walks in milliseconds, so
        // what is left is a handful plus the final total of each shard walked.
        let reported = counter.value
        XCTAssertLessThan(
            reported, directories / 10,
            """
            \(reported) reports for \(directories) directories — the walk is \
            reporting per directory rather than on a clock
            """
        )
        XCTAssertGreaterThan(
            reported, 0, "a walk that reported nothing cannot draw a count"
        )
    }

    /// The clock must not swallow the answer. Whatever else is dropped, the
    /// number a label is left showing has to be the one that turned out true.
    func testTheFinalCountIsAlwaysReported() async throws {
        try buildTree()

        let last = LastValue()
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.startIndexing(
                root: root, skipping: [],
                onProgress: { last.record($0) },
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }

        XCTAssertEqual(
            last.value,
            FileIndexSnapshot.shared.indexedCount(forCanonicalRoot: canonical),
            "the last count reported was not the count the index settled on"
        )
    }

    // MARK: - Counting from a callback that arrives on the main actor

    private final class Counter {
        private var count = 0
        func increment() { count += 1 }
        var value: Int { count }
    }

    private final class LastValue {
        private var last = -1
        func record(_ value: Int) { last = value }
        var value: Int { last }
    }
}
