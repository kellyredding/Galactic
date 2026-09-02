import XCTest

@testable import Galactic

/// The engine, against a real index over a real temp directory.
///
/// The scanner's rules are asserted from string literals in
/// `FileSearchScannerTests`; what only this file can assert is the part that
/// depends on the corpus and the filesystem — that enumeration comes from the
/// index and therefore inherits its skip list, that a file the index offers but
/// the disk no longer has is a skip rather than a failure, and that the counts
/// in the header mean what they say.
@MainActor
final class FileSearchEngineTests: FileIndexIsolatedTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-search-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-search-root-\(UUID().uuidString)")
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

    // MARK: - Harness

    @discardableResult
    private func write(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeBytes(_ relative: String, _ bytes: [UInt8]) throws -> URL
    {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
        return url
    }

    private func indexRoot(skipping skipList: Set<String> = []) async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.startIndexing(
                root: root, skipping: skipList,
                onFinished: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            )
        }
    }

    private func search(
        _ text: String,
        caseSensitive: Bool = false,
        context: Int = 0,
        limits: FileSearchEngine.Limits = .default
    ) async -> FileSearchRun {
        let engine = FileSearchEngine()
        return await withCheckedContinuation { continuation in
            var resumed = false
            engine.search(
                query: FileSearchQuery(
                    text: text,
                    isCaseSensitive: caseSensitive,
                    contextLines: context
                ),
                root: root,
                limits: limits,
                onFinished: { run in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: run)
                }
            )
        }
    }

    // MARK: - Finding things

    func testFindsAMatchInOneFileOfSeveral() async throws {
        try write("a.swift", "let x = 1\n")
        try write("b.swift", "let needle = 2\n")
        try write("c.swift", "let y = 3\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertEqual(run.files.count, 1)
        XCTAssertEqual(run.files.first?.relativePath, "b.swift")
        XCTAssertEqual(run.matchCount, 1)
    }

    func testResultsAreInFileOrder() async throws {
        try write("z.swift", "needle\n")
        try write("a.swift", "needle\n")
        try write("m/inner.swift", "needle\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertEqual(
            run.files.map(\.relativePath), ["a.swift", "m/inner.swift", "z.swift"]
        )
    }

    func testNoMatchesIsAnEmptyRunRatherThanAFailure() async throws {
        try write("a.swift", "nothing here\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertTrue(run.isEmpty)
        XCTAssertEqual(run.matchCount, 0)
        XCTAssertNil(run.truncation)
        XCTAssertGreaterThan(
            run.filesScanned, 0, "the file was still read to find that out"
        )
    }

    func testAnEmptyQueryFindsNothing() async throws {
        try write("a.swift", "anything\n")
        await indexRoot()

        let run = await search("")

        XCTAssertTrue(run.isEmpty)
    }

    func testCaseSensitivityIsHonoured() async throws {
        try write("a.swift", "Needle and needle\n")
        await indexRoot()

        let sensitive = await search("needle", caseSensitive: true)
        let insensitive = await search("needle", caseSensitive: false)

        XCTAssertEqual(sensitive.matchCount, 1)
        XCTAssertEqual(insensitive.matchCount, 2)
    }

    func testTheQueryTravelsWithTheRun() async throws {
        try write("a.swift", "needle\n")
        await indexRoot()

        let run = await search("needle", caseSensitive: true, context: 3)

        XCTAssertEqual(run.query.text, "needle")
        XCTAssertTrue(run.query.isCaseSensitive)
        XCTAssertEqual(run.query.contextLines, 3)
        XCTAssertEqual(run.root, FilePaths.canonical(root))
    }

    func testContextLinesReachTheResult() async throws {
        try write("a.swift", "one\ntwo\nneedle\nfour\nfive\n")
        await indexRoot()

        let run = await search("needle", context: 1)

        let block = try XCTUnwrap(run.files.first?.blocks.first)
        XCTAssertEqual(block.map(\.line), [2, 3, 4])
        XCTAssertEqual(block.filter(\.isMatch).map(\.line), [3])
    }

    // MARK: - What is not read

    func testABinaryFileIsSkipped() async throws {
        try writeBytes("bin.dat", Array("needle".utf8) + [0])
        try write("a.swift", "needle\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertEqual(run.files.map(\.relativePath), ["a.swift"])
    }

    func testAnOversizedFileIsSkipped() async throws {
        try write("big.txt", String(repeating: "needle\n", count: 200))
        try write("small.txt", "needle\n")
        await indexRoot()

        let run = await search(
            "needle",
            limits: FileSearchEngine.Limits(bytesPerFile: 100)
        )

        XCTAssertEqual(run.files.map(\.relativePath), ["small.txt"])
    }

    func testAnEmptyFileIsSkipped() async throws {
        try write("empty.txt", "")
        await indexRoot()

        let run = await search("needle")

        XCTAssertEqual(
            run.filesScanned, 0, "nothing to read means nothing was read"
        )
    }

    /// The searcher inherits the index's skip list, and that is the whole point
    /// of enumerating from the index: the picker cannot show a file in here, so
    /// a search must not find one either.
    func testASkippedDirectoryIsNotSearched() async throws {
        try write("src/a.swift", "needle\n")
        try write("node_modules/dep.js", "needle\n")
        await indexRoot(skipping: ["node_modules"])

        let run = await search("needle")

        XCTAssertEqual(run.files.map(\.relativePath), ["src/a.swift"])
        XCTAssertTrue(
            run.skippedNames.contains("node_modules"),
            "and the run says what it did not look at"
        )
    }

    /// An indexed path is a claim, not a guarantee. A file deleted between the
    /// snapshot and the read must not fail the run.
    func testAFileDeletedSinceIndexingIsSkipped() async throws {
        let doomed = try write("gone.swift", "needle\n")
        try write("here.swift", "needle\n")
        await indexRoot()
        try FileManager.default.removeItem(at: doomed)

        let run = await search("needle")

        XCTAssertEqual(run.files.map(\.relativePath), ["here.swift"])
    }

    func testDirectoriesAreNotSearched() async throws {
        try write("needle/inside.txt", "nothing\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertTrue(
            run.isEmpty,
            "a directory whose name matches is not a file with a match"
        )
    }

    // MARK: - Counting and caps

    func testConsideredAndScannedAreCountedApart() async throws {
        try write("text.txt", "nothing\n")
        try writeBytes("bin.dat", [1, 2, 0, 3])
        await indexRoot()

        let run = await search("needle")

        XCTAssertEqual(run.filesConsidered, 2)
        XCTAssertEqual(
            run.filesScanned, 1, "the binary was offered but never read"
        )
    }

    func testThePerFileCapReportsItself() async throws {
        try write("many.txt", String(repeating: "needle\n", count: 50))
        await indexRoot()

        let run = await search(
            "needle",
            limits: FileSearchEngine.Limits(matchesPerFile: 5)
        )

        XCTAssertEqual(run.files.first?.matchCount, 5)
        XCTAssertEqual(run.files.first?.wasTruncated, true)
        XCTAssertEqual(run.truncation, .fileCap(5))
    }

    func testTheTotalCapReportsItself() async throws {
        for name in ["a", "b", "c", "d"] {
            try write("\(name).txt", String(repeating: "needle\n", count: 5))
        }
        await indexRoot()

        let run = await search(
            "needle",
            limits: FileSearchEngine.Limits(
                totalMatches: 7, matchesPerFile: 50
            )
        )

        XCTAssertEqual(run.truncation, .matchCap(7))
        XCTAssertLessThan(
            run.files.count, 4, "it stopped before every file was included"
        )
    }

    func testAnUncappedRunReportsNoTruncation() async throws {
        try write("a.txt", "needle\n")
        await indexRoot()

        let run = await search("needle")

        XCTAssertNil(run.truncation)
        XCTAssertEqual(run.files.first?.wasTruncated, false)
    }

    // MARK: - Cancellation

    func testCancellingBeforeTheRunLandsDeliversNothing() async throws {
        for i in 0..<200 {
            try write("f\(i).txt", "needle\n")
        }
        await indexRoot()

        let engine = FileSearchEngine()
        var delivered = 0
        engine.search(
            query: FileSearchQuery(
                text: "needle", isCaseSensitive: false, contextLines: 0
            ),
            root: root,
            onFinished: { _ in delivered += 1 }
        )
        engine.cancel()

        // One turn is enough for a landed result to have been delivered.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            delivered, 0, "a cancelled run must not land on its caller"
        )
    }

    func testASecondSearchSupersedesTheFirst() async throws {
        try write("a.txt", "alpha\n")
        try write("b.txt", "beta\n")
        await indexRoot()

        let engine = FileSearchEngine()
        var landed: [String] = []
        func run(_ text: String) {
            engine.search(
                query: FileSearchQuery(
                    text: text, isCaseSensitive: false, contextLines: 0
                ),
                root: root,
                onFinished: { landed.append($0.query.text) }
            )
        }

        run("alpha")
        run("beta")
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            landed, ["beta"],
            "the superseded query must not land after the newer one"
        )
    }
}
