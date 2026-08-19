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
        FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        FileCorpusStore.shared.forgetAll()
        FileIndexRefreshSweep.shared.stop()
        FileIndexRefreshSweep.targetAge = 3_600
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

        let chosen = FileIndexRefreshSweep.shared.nextShard(
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

        let chosen = FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertEqual(
            chosen, "Downloads",
            "a shard something reported wrong was left alone"
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

        let first = FileIndexRefreshSweep.shared.nextShard(
            in: canonical, from: catalog, now: Date()
        )?.name
        XCTAssertNotNil(first)

        FileIndexRefreshSweep.shared.inFlight.insert(
            FileIndexRefreshSweep.inFlightKey(
                root: canonical, shard: try XCTUnwrap(first)
            )
        )
        defer { FileIndexRefreshSweep.shared.inFlight.removeAll() }
        let second = FileIndexRefreshSweep.shared.nextShard(
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
