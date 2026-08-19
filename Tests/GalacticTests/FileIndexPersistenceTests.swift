import XCTest

@testable import Galactic

/// The index on disk: its format, how it is replaced, and the directory it
/// lives in.
final class FileIndexPersistenceTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-home-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        FileIndexPaths.prepare()
    }

    override func tearDownWithError() throws {
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func corpus(_ paths: [String], root: String = "/tmp/root") -> FileCorpus {
        var writer = FileCorpusWriter()
        for path in paths {
            writer.add(relativePath: path, modified: Date(), isDirectory: false)
        }
        return writer.finish(root: root)
    }

    // MARK: - The format

    /// The whole premise: what a walk built and what a file gives back are the
    /// same bytes, so persisting is a write and loading is a map.
    func testACorpusSurvivesAWriteAndAMapUnchanged() throws {
        let paths = (0..<500).map { "pkg\($0 % 10)/file\($0).swift" }
        let original = corpus(paths)
        let url = home.appendingPathComponent("round-trip.gfsi")

        try FileCorpusFile.write(original, to: url)
        let loaded = try XCTUnwrap(FileCorpus.load(from: url))

        XCTAssertEqual(loaded.entryCount, original.entryCount)
        XCTAssertEqual(loaded.root, original.root)
        XCTAssertEqual(
            (0..<loaded.entryCount).map { loaded.relativePath(at: $0) },
            (0..<original.entryCount).map { original.relativePath(at: $0) }
        )
    }

    func testAMappedCorpusStillRanks() throws {
        let url = home.appendingPathComponent("ranked.gfsi")
        try FileCorpusFile.write(corpus(["src/user_model.rb", "docs/readme.md"]), to: url)
        let loaded = try XCTUnwrap(FileCorpus.load(from: url))

        let found = FileMatcher.matches(in: loaded, query: "usermodel", limit: 10)
        XCTAssertEqual(
            found.map { loaded.relativePath(at: $0.index) }, ["src/user_model.rb"]
        )
    }

    func testGarbageIsRejectedRatherThanMisread() throws {
        let url = home.appendingPathComponent("nonsense.gfsi")
        try Data(repeating: 0xAB, count: 40_000).write(to: url)
        // Rebuildable by definition, so refusing to load is the whole
        // contract — the caller's answer to nil is always "walk it again".
        XCTAssertNil(FileCorpus.load(from: url))
    }

    /// A reader mid-search must not see a corpus change underneath it. This is
    /// the property that lets a shard be replaced without any coordination
    /// with the processes reading it.
    func testReplacingAFileLeavesALiveReaderOnTheOldBytes() throws {
        let url = home.appendingPathComponent("live.gfsi")
        try FileCorpusFile.write(corpus(["before.txt"]), to: url)
        let reader = try XCTUnwrap(FileCorpus.load(from: url))

        try FileCorpusFile.write(corpus(["after.txt", "second.txt"]), to: url)

        XCTAssertEqual(reader.entryCount, 1)
        XCTAssertEqual(reader.relativePath(at: 0), "before.txt")

        let reopened = try XCTUnwrap(FileCorpus.load(from: url))
        XCTAssertEqual(reopened.entryCount, 2)
    }

    func testSupersededGenerationsAreRemoved() throws {
        let directory = home.appendingPathComponent("shards")
        for generation in UInt64(1)...3 {
            try FileCorpusFile.write(
                corpus(["a.txt"]),
                to: FileCorpusFile.url(
                    shardDirectory: directory, shard: "s", generation: generation
                )
            )
        }
        FileCorpusFile.removeSupersededGenerations(
            shardDirectory: directory, shard: "s", keeping: 3
        )
        let remaining = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasSuffix(".gfsi") }
        XCTAssertEqual(remaining, ["s-3.gfsi"])
    }

    // MARK: - The directory

    /// The index is a plaintext list of every filename its owner has, so these
    /// are asserted rather than assumed — and re-asserted on every launch, so
    /// a directory restored from a backup is corrected rather than trusted.
    func testPreparingTheDirectoryMakesItPrivate() {
        let privacy = FileIndexPaths.privacyHolds()
        XCTAssertTrue(privacy.excludedFromBackup, "Time Machine would copy it")
        XCTAssertTrue(privacy.spotlightMarker, "Spotlight would index it")
        XCTAssertTrue(privacy.permissions, "another user could read it")
    }

    func testPrivacyIsRestoredIfSomethingUndoesIt() throws {
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(".metadata_never_index")
        )
        XCTAssertFalse(FileIndexPaths.privacyHolds().spotlightMarker)
        FileIndexPaths.prepare()
        XCTAssertTrue(FileIndexPaths.privacyHolds().spotlightMarker)
    }

    func testRootIdentifiersAreStableAndFilesystemSafe() {
        let identifier = FileIndexPaths.rootIdentifier("/Users/someone/projects")
        XCTAssertEqual(identifier, FileIndexPaths.rootIdentifier("/Users/someone/projects"))
        XCTAssertNotEqual(identifier, FileIndexPaths.rootIdentifier("/Users/someone/other"))
        XCTAssertFalse(identifier.contains("/"))
    }

    // MARK: - The lease

    /// One writer at a time, and the lock is taken on a file that is never
    /// replaced — a lock on a renamed-over file guards an orphaned inode.
    func testASecondWriterCannotTakeTheLease() {
        let first = FileIndexLock()
        XCTAssertTrue(first.acquire())
        let second = FileIndexLock()
        XCTAssertFalse(second.acquire(), "two writers held the lease at once")
        first.release()
        XCTAssertTrue(second.acquire())
        second.release()
    }

    // MARK: - The catalog

    func testTheCatalogRemembersShardsAcrossInstances() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: "/tmp/root")
        catalog.record(
            root: "/tmp/root", name: "src", generation: 4, entryCount: 99,
            eventsUUID: "UUID-1", eventsID: 12345
        )

        let reopened = try XCTUnwrap(FileIndexCatalog())
        let shard = try XCTUnwrap(reopened.shards(forRoot: "/tmp/root").first)
        XCTAssertEqual(shard.name, "src")
        XCTAssertEqual(shard.generation, 4)
        XCTAssertEqual(shard.entryCount, 99)
        XCTAssertEqual(shard.eventsID, 12345)
        XCTAssertFalse(shard.dirty)
    }

    /// The rotation asks one question — what is stalest — and a shard the file
    /// system already told us is wrong must come first.
    func testTheStalestShardPrefersDirtyOverMerelyOld() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.record(
            root: "/tmp/root", name: "ancient", generation: 1, entryCount: 1,
            walkedAt: Date(timeIntervalSinceNow: -100_000),
            eventsUUID: nil, eventsID: nil
        )
        catalog.record(
            root: "/tmp/root", name: "recent", generation: 1, entryCount: 1,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil
        )
        XCTAssertEqual(catalog.stalestShard(forRoot: "/tmp/root")?.name, "ancient")

        catalog.markDirty(root: "/tmp/root", name: "recent")
        XCTAssertEqual(catalog.stalestShard(forRoot: "/tmp/root")?.name, "recent")
    }

    // MARK: - The log

    func testTheLogWritesWhatItWasGiven() {
        let log = FileIndexLog()
        log.record("walk", [("shard", "src"), ("entries", "42")])
        log.drain()
        let line = try? String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(line?.contains("[walk] shard=src entries=42"), true)
    }

    /// An index maintains itself for days. An unbounded log would be the one
    /// part of it that grows without limit, which is the failure it exists to
    /// help diagnose.
    func testTheLogRotatesAndStopsGrowing() throws {
        let log = FileIndexLog()
        let filler = String(repeating: "x", count: 512)
        for index in 0..<20_000 {
            log.record("bulk", [("n", "\(index)"), ("pad", filler)])
        }
        log.drain()

        let directory = FileIndexPaths.logsDirectory
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("index.log") }
        XCTAssertTrue(
            files.contains("index.log.1"), "nothing was rotated: \(files)"
        )
        XCTAssertLessThanOrEqual(
            files.count, FileIndexLog.generationsKept + 1,
            "generations are not bounded: \(files)"
        )
        let total = files.reduce(0) { sum, name in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            return sum + ((attributes?[.size] as? Int) ?? 0)
        }
        XCTAssertLessThan(
            total,
            (FileIndexLog.generationsKept + 2) * FileIndexLog.rotateAtBytes,
            "the log is not bounded in total size"
        )
    }
}

extension FileIndexPersistenceTests {

    /// The lease is per-write, not per-process. Held for the life of a process
    /// it would mean whichever application launched first owned the index
    /// forever, and the second would re-walk on every launch while the first
    /// paid nothing.
    func testTheLeaseIsReleasedSoAnotherWriterCanTakeIt() {
        let first = FileIndexLock()
        XCTAssertTrue(first.acquire())
        first.release()

        let second = FileIndexLock()
        XCTAssertTrue(
            second.acquire(), "the lease outlived the write that needed it"
        )
        second.release()
    }
}
