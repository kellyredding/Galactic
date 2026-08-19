import XCTest

@testable import Galactic

/// Keeping the index true after the walk: files appearing, disappearing, being
/// renamed, and the rotation that catches whatever the file system did not
/// tell us about.
@MainActor
final class FileIndexLiveTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-live-home-\(UUID().uuidString)")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-live-root-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        FileCorpusStore.shared.forgetAll()
        FileIndexRefreshRotation.shared.stop()
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private var canonical: String { FilePaths.canonical(root) }

    private func indexRoot(skipping skipList: Set<String> = []) async {
        await withCheckedContinuation { continuation in
            var resumed = false
            FileCorpusStore.shared.index(
                root: root, skipping: skipList,
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

    // MARK: - The walk, and then not walking again

    func testIndexingARootFindsItsFiles() async throws {
        try touch("src/user_model.rb")
        try touch("docs/readme.md")
        await indexRoot()

        XCTAssertEqual(found("usermodel"), ["src/user_model.rb"])
        XCTAssertEqual(found("readme"), ["docs/readme.md"])
    }

    /// The point of persisting: a second process (here, a second store) finds
    /// the index already built and walks nothing.
    func testASecondStoreMapsTheIndexInsteadOfWalking() async throws {
        try touch("src/one.swift")
        try touch("src/two.swift")
        await indexRoot()
        let before = FileCorpusStore.shared.indexedCount(forCanonicalRoot: canonical)

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let generations = catalog.shards(forRoot: canonical)
            .map { "\($0.name):\($0.generation)" }.sorted()

        FileCorpusStore.shared.forgetAll()
        await indexRoot()

        XCTAssertEqual(
            FileCorpusStore.shared.indexedCount(forCanonicalRoot: canonical), before
        )
        XCTAssertEqual(
            catalog.shards(forRoot: canonical)
                .map { "\($0.name):\($0.generation)" }.sorted(),
            generations,
            "a shard was rewritten, so the second load walked instead of mapping"
        )
    }

    // MARK: - Live updates

    func testACreatedFileBecomesFindableWithoutAWalk() async throws {
        try touch("src/existing.swift")
        await indexRoot()
        XCTAssertTrue(found("brandnew").isEmpty)

        let created = try touch("src/brand_new_file.swift")
        FileCorpusStore.shared.noteCreated([created.path], canonicalRoot: canonical)

        XCTAssertEqual(found("brandnew"), ["src/brand_new_file.swift"])
    }

    func testADeletedFileStopsBeingFound() async throws {
        let doomed = try touch("src/doomed.swift")
        try touch("src/keeper.swift")
        await indexRoot()
        XCTAssertEqual(found("doomed"), ["src/doomed.swift"])

        try FileManager.default.removeItem(at: doomed)
        FileCorpusStore.shared.noteRemoved([doomed.path], canonicalRoot: canonical)

        XCTAssertTrue(found("doomed").isEmpty, "a deleted file is still offered")
        XCTAssertEqual(found("keeper"), ["src/keeper.swift"], "its neighbour went too")
    }

    /// A rename is the case that catches a design that trusts event flags: it
    /// arrives as one path that no longer exists and one that now does.
    func testARenamedFileMovesInTheIndex() async throws {
        let before = try touch("src/before_name.swift")
        await indexRoot()
        XCTAssertEqual(found("beforename"), ["src/before_name.swift"])

        let after = root.appendingPathComponent("src/after_name.swift")
        try FileManager.default.moveItem(at: before, to: after)
        FileCorpusStore.shared.apply(
            touched: [before.path, after.path], rescan: [],
            canonicalRoot: canonical
        )

        XCTAssertTrue(found("beforename").isEmpty, "the old name still resolves")
        XCTAssertEqual(found("aftername"), ["src/after_name.swift"])
    }

    func testARecreatedFileIsFoundAgain() async throws {
        let path = try touch("src/flapping.swift")
        await indexRoot()

        try FileManager.default.removeItem(at: path)
        FileCorpusStore.shared.apply(
            touched: [path.path], rescan: [], canonicalRoot: canonical
        )
        XCTAssertTrue(found("flapping").isEmpty)

        try Data("x".utf8).write(to: path)
        FileCorpusStore.shared.apply(
            touched: [path.path], rescan: [], canonicalRoot: canonical
        )
        XCTAssertEqual(found("flapping"), ["src/flapping.swift"])
    }

    // MARK: - The rotation

    /// The backstop. A file created while nothing was watching is invisible
    /// until the shard it belongs to is walked again — which is exactly what
    /// the rotation is for, so this proves it recovers rather than waiting an
    /// hour to find out.
    func testTheRotationPicksUpAChangeNothingReported() async throws {
        try touch("src/original.swift")
        await indexRoot()

        // Created behind the index's back: no event, no notification.
        try touch("src/unreported.swift")
        XCTAssertTrue(found("unreported").isEmpty, "the fixture proved nothing")

        FileIndexRefreshRotation.targetAge = 0
        defer { FileIndexRefreshRotation.targetAge = 3_600 }
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)

        var refreshed: Set<String> = []
        for _ in 0..<8 {
            if let shard = await FileIndexRefreshRotation.shared.tick() {
                refreshed.insert(shard)
            }
            if !found("unreported").isEmpty { break }
        }

        XCTAssertEqual(
            found("unreported"), ["src/unreported.swift"],
            "the rotation never reached the stale shard; it refreshed \(refreshed)"
        )
    }

    /// A rewalk must fold the overlay in rather than leaving it to be applied
    /// twice — a file recorded as added and then found by the walk would
    /// otherwise appear once from each.
    func testARefreshAbsorbsTheOverlayWithoutDuplicating() async throws {
        try touch("src/first.swift")
        await indexRoot()

        let created = try touch("src/second.swift")
        FileCorpusStore.shared.noteCreated([created.path], canonicalRoot: canonical)
        XCTAssertEqual(found("second"), ["src/second.swift"])

        FileIndexRefreshRotation.targetAge = 0
        defer { FileIndexRefreshRotation.targetAge = 3_600 }
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)
        for _ in 0..<8 { _ = await FileIndexRefreshRotation.shared.tick() }

        XCTAssertEqual(
            found("second"), ["src/second.swift"],
            "the file is listed twice, or lost, after being folded in"
        )
    }

    // MARK: - End to end

    /// The real thing: a live FSEvents stream, a real file, no manual
    /// notification. Slow by nature — the stream coalesces on a latency window
    /// — so it polls rather than assuming a fixed delay.
    func testFileSystemEventsUpdateTheIndexOnTheirOwn() async throws {
        try touch("src/seed.swift")
        await indexRoot()
        XCTAssertTrue(found("watched").isEmpty)

        try touch("src/watched_by_events.swift")

        var appeared = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !found("watched").isEmpty { appeared = true; break }
        }
        XCTAssertTrue(
            appeared,
            "a file created under a watched root never reached the index"
        )

        let created = root.appendingPathComponent("src/watched_by_events.swift")
        try FileManager.default.removeItem(at: created)

        var vanished = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if found("watched").isEmpty { vanished = true; break }
        }
        XCTAssertTrue(vanished, "a deleted file stayed in the index")
    }
}

extension FileIndexLiveTests {

    /// A directory created after the index was built has no shard of its own,
    /// so its files land in the overlay. If nothing ever adopted it, that
    /// overlay would grow forever — correct results, unbounded memory — since
    /// folding happens when a shard is walked and there was no shard.
    func testANewTopLevelDirectoryEventuallyGetsItsOwnShard() async throws {
        try touch("existing/file.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        XCTAssertNil(
            catalog.shards(forRoot: canonical).first { $0.name == "arrived_later" }
        )

        try touch("arrived_later/deep/file.swift")

        FileIndexRefreshRotation.targetAge = 0
        defer { FileIndexRefreshRotation.targetAge = 3_600 }
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)
        for _ in 0..<10 { _ = await FileIndexRefreshRotation.shared.tick() }

        XCTAssertNotNil(
            catalog.shards(forRoot: canonical).first { $0.name == "arrived_later" },
            "a directory created after indexing never got a shard"
        )
        XCTAssertEqual(
            found("arrivedlaterdeep"), ["arrived_later/deep/file.swift"]
        )
    }
}

extension FileIndexLiveTests {

    /// The file system reports everything, including the trees the walk
    /// refuses to descend into. Without the same filter on this side, one
    /// compile put eleven thousand build artefacts into the overlay on a real
    /// machine — the exact noise the skip list exists to exclude, arriving
    /// through the other door.
    func testEventsInSkippedDirectoriesAreIgnored() async throws {
        try touch("src/real.swift")
        await indexRoot(skipping: [".build"])

        let noise = root.appendingPathComponent(".build/artifacts/object.o")
        try FileManager.default.createDirectory(
            at: noise.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: noise)

        FileCorpusStore.shared.noteCreated([noise.path], canonicalRoot: canonical)
        XCTAssertTrue(
            found("object").isEmpty, "a build artefact reached the index"
        )
    }

    func testTheSkipRuleMatchesDirectoriesNotFiles() {
        let skip: Set<String> = ["build", "node_modules"]
        XCTAssertFalse(FileCorpusStore.isIndexable("build/output.o", skipping: skip))
        XCTAssertFalse(
            FileCorpusStore.isIndexable("app/node_modules/pkg/index.js", skipping: skip)
        )
        // A *file* named `build` is still a file — the same distinction the
        // walk makes, and one an earlier reordering of that check broke.
        XCTAssertTrue(FileCorpusStore.isIndexable("src/build", skipping: skip))
        XCTAssertTrue(FileCorpusStore.isIndexable("src/main.swift", skipping: skip))
    }
}

extension FileIndexLiveTests {

    /// Sorted order makes a subtree a contiguous range, which is what is
    /// supposed to make nesting free. Before this, browsing a directory inside
    /// an indexed root walked it again from scratch — on a real machine that
    /// was fifteen seconds to rebuild four hundred thousand entries the index
    /// already held.
    func testASubtreeOfAnIndexedRootIsNotWalkedAgain() async throws {
        try touch("projects/deep/nested/target_file.swift")
        try touch("elsewhere/other.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        let generationsBefore = catalog.shards(forRoot: canonical)
            .map { "\($0.name):\($0.generation)" }.sorted()

        let subroot = root.appendingPathComponent("projects")
        let subCanonical = FilePaths.canonical(subroot)
        await withCheckedContinuation { continuation in
            var done = false
            FileCorpusStore.shared.index(
                root: subroot, skipping: [],
                onFinished: { if !done { done = true; continuation.resume() } }
            )
        }

        XCTAssertTrue(
            catalog.shards(forRoot: subCanonical).isEmpty,
            "the subtree was indexed as a root of its own"
        )
        XCTAssertEqual(
            catalog.shards(forRoot: canonical)
                .map { "\($0.name):\($0.generation)" }.sorted(),
            generationsBefore,
            "something was rewalked"
        )
    }

    /// And what it finds is scoped to that subtree, with paths shown relative
    /// to it rather than to the root it is actually served from.
    func testBrowsingASubtreeSeesOnlyItAndNamesItCorrectly() async throws {
        try touch("projects/inside/target_file.swift")
        try touch("elsewhere/target_file.swift")
        await indexRoot()

        let subroot = root.appendingPathComponent("projects")
        let subCanonical = FilePaths.canonical(subroot)
        await withCheckedContinuation { continuation in
            var done = false
            FileCorpusStore.shared.index(
                root: subroot, skipping: [],
                onFinished: { if !done { done = true; continuation.resume() } }
            )
        }

        let slices = FileCorpusStore.shared.slices(forCanonicalRoot: subCanonical)
        let rows = FilePickerRanking.matches(
            slices, query: "targetfile", relativeTo: subCanonical
        )
        XCTAssertEqual(
            rows.map(\.relativePath), ["inside/target_file.swift"],
            "the sibling subtree leaked in, or the path is named from the wrong root"
        )
    }
}

extension FileIndexLiveTests {

    /// A directory going away takes everything under it, and the file system
    /// says nothing about the children — they never changed. Clearing one bit
    /// for the directory itself would leave every path beneath it resolving to
    /// a file that is gone.
    func testRemovingADirectoryEventuallyClearsItsChildren() async throws {
        try touch("doomed_dir/inner/leaf_file.swift")
        try touch("keeper/other.swift")
        await indexRoot()
        XCTAssertEqual(
            found("leaffile"), ["doomed_dir/inner/leaf_file.swift"],
            "precondition: the child was indexed"
        )

        let directory = root.appendingPathComponent("doomed_dir")
        try FileManager.default.removeItem(at: directory)
        // Only the directory is reported, which is what the file system does.
        FileCorpusStore.shared.noteRemoved([directory.path], canonicalRoot: canonical)

        FileIndexRefreshRotation.targetAge = 0
        defer { FileIndexRefreshRotation.targetAge = 3_600 }
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)
        for _ in 0..<10 {
            _ = await FileIndexRefreshRotation.shared.tick()
            if found("leaffile").isEmpty { break }
        }

        XCTAssertTrue(
            found("leaffile").isEmpty,
            "a child of a removed directory still resolves"
        )
        XCTAssertEqual(
            found("other"), ["keeper/other.swift"], "an unrelated subtree was harmed"
        )
    }

    /// The overlay used to be bounded only by time — it drained when the
    /// rotation reached a shard, an hour away at the earliest — so an active
    /// hour grew it without limit while every batch of events re-encoded the
    /// whole thing. Size has to provoke compaction too.
    func testALargeOverlayMarksItsShardForRewalk() async throws {
        try touch("busy/seed.swift")
        await indexRoot()

        let catalog = try XCTUnwrap(FileIndexCatalog())
        XCTAssertFalse(
            catalog.shards(forRoot: canonical).first { $0.name == "busy" }?.dirty
                ?? true,
            "precondition: the shard starts clean"
        )

        var created: [String] = []
        for index in 0..<(FileCorpusStore.overlayCompactionThreshold + 10) {
            let url = root.appendingPathComponent("busy/generated_\(index).swift")
            try Data("x".utf8).write(to: url)
            created.append(url.path)
        }
        FileCorpusStore.shared.noteCreated(created, canonicalRoot: canonical)

        XCTAssertTrue(
            catalog.shards(forRoot: canonical).first { $0.name == "busy" }?.dirty
                ?? false,
            "the overlay passed the threshold and nothing asked for a rewalk"
        )
    }

    /// `pending=306` with no attribution cannot answer "where is it coming
    /// from", which is the only question worth asking of that number.
    func testTheOverlayCanSayWhichSubtreeItIsAccumulatingIn() async throws {
        try touch("alpha/seed.swift")
        try touch("beta/seed.swift")
        await indexRoot()

        var created: [String] = []
        for index in 0..<5 {
            let url = root.appendingPathComponent("alpha/new_\(index).swift")
            try Data("x".utf8).write(to: url)
            created.append(url.path)
        }
        let single = root.appendingPathComponent("beta/new.swift")
        try Data("x".utf8).write(to: single)
        created.append(single.path)
        FileCorpusStore.shared.noteCreated(created, canonicalRoot: canonical)

        let breakdown = FileCorpusStore.shared.overlayByShard(
            forCanonicalRoot: canonical
        )
        XCTAssertEqual(breakdown["alpha"], 5)
        XCTAssertEqual(breakdown["beta"], 1)
    }
}

extension FileIndexLiveTests {

    /// Marking a subtree dirty is idempotent, and during build churn the same
    /// one is marked over and over. Each repetition used to cost a database
    /// write and a log line on the main thread — dozens a second, which is
    /// what a beach ball looks like from the inside.
    func testRepeatedDirtyMarksCostNothingAfterTheFirst() async throws {
        try touch("churn/seed.swift")
        await indexRoot()

        let target = root.appendingPathComponent("churn/whatever").path
        for _ in 0..<50 {
            FileCorpusStore.shared.markSubtreeDirty(
                target, canonicalRoot: canonical, reason: "test"
            )
        }
        FileIndexLog.shared.drain()

        let marks = FileIndexLog.shared.tail(200)
            .filter { $0.contains("event=marked-dirty") && $0.contains("reason=test") }
        XCTAssertEqual(
            marks.count, 1,
            "fifty identical marks produced \(marks.count) writes"
        )
    }

    /// And once the shard has actually been walked, a fresh mark is allowed
    /// through again — otherwise the first dirty flag of the process would be
    /// the last one it ever recorded.
    func testADirtyMarkIsAllowedAgainAfterTheRewalk() async throws {
        try touch("churn/seed.swift")
        await indexRoot()

        let target = root.appendingPathComponent("churn/whatever").path
        FileCorpusStore.shared.markSubtreeDirty(
            target, canonicalRoot: canonical, reason: "first"
        )

        FileIndexRefreshRotation.targetAge = 0
        defer { FileIndexRefreshRotation.targetAge = 3_600 }
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)
        for _ in 0..<10 { _ = await FileIndexRefreshRotation.shared.tick() }

        FileCorpusStore.shared.markSubtreeDirty(
            target, canonicalRoot: canonical, reason: "second"
        )
        FileIndexLog.shared.drain()

        XCTAssertTrue(
            FileIndexLog.shared.tail(400).contains { $0.contains("reason=second") },
            "the shard was rewalked but a later mark was still suppressed"
        )
    }
}

extension FileIndexLiveTests {

    /// The watcher classifies paths on its own queue and hands over the answers,
    /// so the store must trust what it was told rather than asking again.
    ///
    /// Proved by describing a path that does not exist on disk: a store that
    /// still stats would find nothing and drop it, and one that uses what it was
    /// given indexes it. That distinction is worth 213 ms of `stat` per nine
    /// hundred paths, which is what it cost on the main actor before.
    func testACarriedAppearanceIsTrustedWithoutRestatting() async throws {
        try touch("src/real.swift")
        await indexRoot()

        let imaginary = root.appendingPathComponent("src/never_written.swift")
        FileCorpusStore.shared.noteCreated(
            [
                FileCorpusStore.Appearance(
                    path: imaginary.path, modified: Date(), isDirectory: false
                )
            ],
            canonicalRoot: canonical
        )

        XCTAssertEqual(
            found("neverwritten"), ["src/never_written.swift"],
            "the store re-statted instead of trusting the classification"
        )
    }

    /// And the classification itself: existence decides, which is what makes a
    /// rename fall out as one path leaving and another arriving.
    func testClassifySplitsByWhatStillExists() throws {
        let present = try touch("src/here.swift")
        let absent = root.appendingPathComponent("src/gone.swift")

        let classified = FileCorpusStore.classify([present.path, absent.path])

        XCTAssertEqual(classified.created.map(\.path), [present.path])
        XCTAssertEqual(classified.removed, [absent.path])
        XCTAssertNotNil(classified.created.first?.modified)
        XCTAssertEqual(classified.created.first?.isDirectory, false)
    }

    func testClassifyReportsDirectoriesAsSuch() throws {
        _ = try touch("adir/inner.swift")
        let directory = root.appendingPathComponent("adir")
        let classified = FileCorpusStore.classify([directory.path])
        XCTAssertEqual(classified.created.first?.isDirectory, true)
    }
}
