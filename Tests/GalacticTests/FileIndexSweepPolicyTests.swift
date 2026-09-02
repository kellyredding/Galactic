import XCTest

@testable import Galactic

/// Which shards the sweep is willing to rewalk, and when.
///
/// The sweep exists because the file system drops events. Acting on that by the
/// clock is right for a tree being worked in and wrong for a directory macOS
/// asks the user about: re-reading one costs a consent dialog, so a timer turns
/// a permission granted once into a permission requested hourly.
@MainActor
final class FileIndexSweepPolicyTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-policy-home-\(UUID().uuidString)")
        root = URL(fileURLWithPath: NSHomeDirectory())
        setenv("GALACTIC_HOME", home.path, 1)
        await FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        await FileCorpusStore.shared.forgetAll()
        await FileIndexRefreshSweep.shared.stop()
        await FileIndexRefreshSweep.shared.releaseAll()
        FileIndexRefreshSweep.targetAge = 3_600
        FileIndexRefreshSweep.refusalBackoff = 86_400
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try await super.tearDown()
    }

    private var canonical: String { FilePaths.canonical(root) }

    // MARK: - What counts as protected

    func testTheAskedAboutDirectoriesUnderHomeAreProtected() {
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"] {
            XCTAssertTrue(
                FileCorpusBuilder.isConsentProtected(
                    shard: name, underCanonicalRoot: canonical
                ),
                "\(name) under the home directory raises a dialog"
            )
        }
    }

    /// The name alone means nothing. A checkout may hold a `Documents`
    /// directory, and exempting it would quietly stop ordinary source being
    /// kept fresh.
    func testTheSameNameElsewhereIsNotProtected() {
        for name in ["Documents", "Downloads", "Pictures"] {
            XCTAssertFalse(
                FileCorpusBuilder.isConsentProtected(
                    shard: name, underCanonicalRoot: "/tmp/some-checkout"
                ),
                "\(name) inside a checkout raises nothing"
            )
        }
    }

    func testOrdinaryDirectoriesUnderHomeAreNotProtected() {
        XCTAssertFalse(
            FileCorpusBuilder.isConsentProtected(
                shard: "projects", underCanonicalRoot: canonical
            )
        )
        XCTAssertFalse(
            FileCorpusBuilder.isConsentProtected(
                shard: "", underCanonicalRoot: canonical
            ),
            "the root's own shard is not a protected directory"
        )
    }

    // MARK: - Fairness across roots

    /// Every root is reached before any root is reached twice.
    ///
    /// Sorted order plus returning after the first eligible shard made position
    /// in the alphabet into policy: one home directory never noticed, but an
    /// application with a session per tab would refresh early roots forever and
    /// late ones never.
    func testTheRotationReachesEveryRootBeforeRepeatingOne() {
        let roots = ["/a", "/b", "/c", "/d"]
        var served: [String] = []
        var last: String?
        for _ in roots {
            let next = try! XCTUnwrap(
                FileIndexRefreshSweep.rotated(roots, after: last).first
            )
            served.append(next)
            last = next
        }
        XCTAssertEqual(
            served.sorted(), roots,
            "a root was served twice before another was served at all: \(served)"
        )
    }

    func testTheRotationStartsAtTheTopWhenNothingHasBeenServed() {
        XCTAssertEqual(
            FileIndexRefreshSweep.rotated(["/a", "/b"], after: nil), ["/a", "/b"]
        )
    }

    /// A root that has gone away since it was last served must not strand the
    /// rotation at a position that no longer exists.
    func testARootThatDisappearedDoesNotStallTheRotation() {
        XCTAssertEqual(
            FileIndexRefreshSweep.rotated(["/a", "/b"], after: "/gone"),
            ["/a", "/b"]
        )
    }

    // MARK: - What the sweep will act on

    /// Age alone does not qualify a protected directory. Everything else, it does.
    func testAgeAloneDoesNotRewalkAProtectedDirectory() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        let ancient = Date(timeIntervalSince1970: 0)
        catalog.adopt(root: canonical)
        for name in ["Downloads", "projects"] {
            catalog.record(
                root: canonical, name: name, generation: 1, entryCount: 5,
                walkedAt: ancient, eventsUUID: nil, eventsID: nil
            )
        }

        let chosen = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertEqual(
            chosen, "projects",
            "the sweep reached for a directory the user would be asked about"
        )
    }

    /// Evidence does qualify it. Something reported the shard wrong, and stale
    /// results are worse than a dialog.
    func testEvidenceRewalksAProtectedDirectory() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        // Fresh, so age cannot be what selects it.
        catalog.record(
            root: canonical, name: "Downloads", generation: 1, entryCount: 5,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil
        )
        catalog.markDirty(root: canonical, name: "Downloads")

        let chosen = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertEqual(
            chosen, "Downloads",
            "a shard something reported wrong was left alone"
        )
    }

    // MARK: - Backing off after a refusal

    /// Evidence qualifies a protected directory once, not repeatedly.
    ///
    /// The policy above assumed a dirty mark names a directory. A replay does
    /// not: one marked all 44 shards at once, and `Music` was selected on that
    /// basis, spending a dialog and 27.96s to return two entries and a
    /// refusal. Having already learned the answer is "you cannot read this",
    /// asking again the same day buys nothing.
    func testAProtectedDirectoryThatCameBackIncompleteIsLeftAlone() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.record(
            root: canonical, name: "Downloads", generation: 1, entryCount: 2,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil,
            refusedDirectoryCount: 1
        )
        catalog.markDirty(root: canonical, name: "Downloads")

        let selected = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )
        XCTAssertNil(
            selected,
            "a refusal was bought a second time inside the backoff"
        )
    }

    /// The backoff expires. A refusal is a fact about a moment, not forever —
    /// consent may since have been granted.
    func testTheRefusalBackoffExpires() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.record(
            root: canonical, name: "Downloads", generation: 1, entryCount: 2,
            walkedAt: Date(timeIntervalSinceNow: -172_800),
            eventsUUID: nil, eventsID: nil, refusedDirectoryCount: 1
        )
        catalog.markDirty(root: canonical, name: "Downloads")

        let selected = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertEqual(
            selected, "Downloads",
            "a day-old refusal still suppressed the rewalk"
        )
    }

    /// The backoff is about the dialog, not about incompleteness. An ordinary
    /// tree with an unreadable subdirectory is still worth rewalking promptly.
    func testAnOpenDirectoryThatCameBackIncompleteIsStillRewalked() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.record(
            root: canonical, name: "projects", generation: 1, entryCount: 5,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil,
            refusedDirectoryCount: 1
        )
        catalog.markDirty(root: canonical, name: "projects")

        let selected = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertEqual(
            selected, "projects",
            "the backoff reached a directory that costs no dialog"
        )
    }

    /// A shard already being walked is not chosen again — which is what lets a
    /// blocked walk be routed around instead of blocking everything.
    func testAShardAlreadyInFlightIsSkippedForAnother() async throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        let ancient = Date(timeIntervalSince1970: 0)
        catalog.adopt(root: canonical)
        for name in ["projects", "code"] {
            catalog.record(
                root: canonical, name: name, generation: 1, entryCount: 5,
                walkedAt: ancient, eventsUUID: nil, eventsID: nil
            )
        }

        let first = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertNotNil(first)

        // Released in `tearDown` rather than by a `defer`, which cannot enter
        // an actor to undo this.
        await FileIndexRefreshSweep.shared.hold(
            shard: try XCTUnwrap(first), inRoot: canonical
        )
        let second = await FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertNotNil(
            second, "one busy shard left the sweep with nothing else to do"
        )
        XCTAssertNotEqual(
            second, first, "the busy shard was chosen a second time"
        )
    }
}
