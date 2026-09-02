import XCTest

@testable import Galactic

/// Whether a dirty mark actually landed, and whether the caller can tell.
///
/// Marking is an `UPDATE`, so naming a shard the catalog has no row for is
/// well-formed and changes nothing. That is indistinguishable from success
/// unless the count of changed rows is reported, and the distinction is not
/// academic: callers remember which shards they have marked so as not to mark
/// them twice, and the sweep only ever selects shards this table knows about.
/// A mark that silently landed nowhere therefore retires a shard permanently
/// — which is how one dependency cache came to hold 24,278 overlay entries
/// that nothing could ever compact.
@MainActor
final class FileIndexMarkDurabilityTests: XCTestCase {

    private var home: URL!
    private let canonical = "/tmp/mark-durability-root"

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("galactic-mark-home-\(UUID().uuidString)")
        setenv("GALACTIC_HOME", home.path, 1)
        await FileCorpusStore.shared.forgetAll()
        FileIndexPaths.prepare()
    }

    override func tearDown() async throws {
        await FileCorpusStore.shared.forgetAll()
        unsetenv("GALACTIC_HOME")
        try? FileManager.default.removeItem(at: home)
        try await super.tearDown()
    }

    // MARK: - Reporting

    func testMarkingAKnownShardReportsSuccess() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.record(
            root: canonical, name: "projects", generation: 1, entryCount: 5,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil
        )

        XCTAssertTrue(catalog.markDirty(root: canonical, name: "projects"))
    }

    /// The case the whole change exists for.
    func testMarkingAShardWithNoRowReportsFailure() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)

        XCTAssertFalse(
            catalog.markDirty(root: canonical, name: "go"),
            "a shard with no row reported as marked"
        )
    }

    func testMarkingUnderAnUnknownRootReportsFailure() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())

        XCTAssertFalse(
            catalog.markDirty(root: "/tmp/never-adopted", name: "projects")
        )
    }

    // MARK: - What a landed mark does

    /// Reporting is not the whole of it: the mark still has to be durable, or
    /// the sweep has nothing to select on.
    func testALandedMarkIsVisibleToTheSweep() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)
        catalog.record(
            root: canonical, name: "projects", generation: 1, entryCount: 5,
            walkedAt: Date(), eventsUUID: nil, eventsID: nil
        )
        XCTAssertTrue(catalog.markDirty(root: canonical, name: "projects"))

        let shard = catalog.shards(forRoot: canonical)
            .first { $0.name == "projects" }
        XCTAssertEqual(shard?.dirty, true)
        XCTAssertEqual(
            FileIndexRefreshSweep.shared.nextShard(
                in: canonical, from: catalog, now: Date()
            )?.name,
            "projects",
            "a freshly walked shard was not selected on the strength of the mark"
        )
    }

    /// And a mark that did not land leaves the sweep with nothing, rather than
    /// with a shard it cannot see.
    func testALostMarkLeavesTheSweepNothingToDo() throws {
        let catalog = try XCTUnwrap(FileIndexCatalog())
        catalog.adopt(root: canonical)

        XCTAssertFalse(catalog.markDirty(root: canonical, name: "go"))
        XCTAssertNil(
            FileIndexRefreshSweep.shared.nextShard(
                in: canonical, from: catalog, now: Date()
            )
        )
    }
}
