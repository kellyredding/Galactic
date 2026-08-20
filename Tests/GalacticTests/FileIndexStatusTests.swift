import XCTest

@testable import Galactic

/// Turning a catalog row into something sayable.
///
/// The whole reason this layer exists is that entry count does not distinguish
/// the cases anyone cares about: a shard holding nothing may be empty, may be
/// refused, or may never have been read, and only one of those is worth telling
/// someone about.
final class FileIndexStatusTests: XCTestCase {

    private func shard(
        name: String = "Documents",
        generation: UInt64 = 4,
        entryCount: Int = 3,
        walkedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        dirty: Bool = false,
        refusedAt: Date? = nil,
        refusalCode: Int32? = nil,
        refusedDirectoryCount: Int = 0
    ) -> FileIndexCatalog.Shard {
        FileIndexCatalog.Shard(
            root: "/Users/someone",
            name: name,
            generation: generation,
            entryCount: entryCount,
            walkedAt: walkedAt,
            dirty: dirty,
            eventsUUID: nil,
            eventsID: nil,
            refusedAt: refusedAt,
            refusalCode: refusalCode,
            refusedDirectoryCount: refusedDirectoryCount
        )
    }

    private func status(
        _ row: FileIndexCatalog.Shard, root: String = "/Users/someone"
    ) -> FileIndexShardStatus {
        FileIndexStatusReport.status(for: row, root: root)
    }

    // MARK: - The three ways to hold nothing

    func testACompletedWalkIsIndexed() {
        XCTAssertEqual(status(shard()).state, .indexed)
    }

    func testAnEmptyShardIsStillIndexed() {
        XCTAssertEqual(status(shard(entryCount: 0)).state, .indexed)
    }

    func testARefusedShardReportsItsCode() {
        let row = shard(entryCount: 0, refusedAt: Date(), refusalCode: EACCES)
        XCTAssertEqual(status(row).state, .refused(code: EACCES))
    }

    func testAShardThatNeverPublishedIsAwaitingAWalk() {
        let row = shard(generation: 0, entryCount: 0)
        XCTAssertEqual(status(row).state, .awaitingWalk)
        XCTAssertNil(
            status(row).walkedAt,
            "a placeholder's walk time is the epoch, not a measurement"
        )
    }

    /// A refusal outranks the placeholder, because a shard refused before it ever
    /// published is both — and "we were not allowed in" is the actionable half.
    func testARefusalOutranksNeverHavingWalked() {
        let row = shard(
            generation: 0, entryCount: 0, refusedAt: Date(), refusalCode: EPERM
        )
        XCTAssertEqual(status(row).state, .refused(code: EPERM))
        XCTAssertNotNil(
            status(row).walkedAt, "the attempt itself is worth reporting"
        )
    }

    func testARefusedDirectoryInsideMakesTheShardIncomplete() {
        let row = shard(refusedDirectoryCount: 2)
        XCTAssertEqual(status(row).state, .incomplete(refusedDirectories: 2))
        XCTAssertFalse(status(row).isComplete)
    }

    func testOnlyACleanWalkIsComplete() {
        XCTAssertTrue(status(shard()).isComplete)
        XCTAssertFalse(status(shard(refusedDirectoryCount: 1)).isComplete)
        XCTAssertFalse(status(shard(refusedAt: Date())).isComplete)
        XCTAssertFalse(status(shard(generation: 0)).isComplete)
    }

    // MARK: - Consent-protected folders are recognised by where they are

    func testAHomeDirectoryDocumentsFolderIsConsentProtected() {
        let home = FilePaths.canonical(URL(fileURLWithPath: NSHomeDirectory()))
        let row = shard(name: "Documents")
        XCTAssertTrue(status(row, root: home).isConsentProtected)
    }

    func testADocumentsFolderInACheckoutIsNot() {
        let row = shard(name: "Documents")
        XCTAssertFalse(status(row, root: "/tmp/some-checkout").isConsentProtected)
    }

    // MARK: - The root's own shard

    func testTheRootShardIsNamedForAReader() {
        XCTAssertEqual(status(shard(name: "")).displayName, "Root files")
        XCTAssertEqual(status(shard(name: "projects")).displayName, "projects")
    }

    // MARK: - Ordering what needs doing

    /// Worst first, and a refusal is worst: it is the only state whose entry
    /// count is a number the index can no longer stand behind.
    func testAttentionIsOrderedWorstFirst() {
        let report = FileIndexStatusReport.report(
            for: [
                shard(name: "fine"),
                shard(name: "partial", refusedDirectoryCount: 1),
                shard(name: "never", generation: 0, entryCount: 0),
                shard(name: "denied", refusedAt: Date(), refusalCode: EPERM),
            ],
            root: "/Users/someone"
        )
        XCTAssertEqual(
            report.needingAttention.map(\.name), ["denied", "never", "partial"]
        )
    }

    func testACleanIndexNeedsNoAttention() {
        let report = FileIndexStatusReport.report(
            for: [shard(name: "a"), shard(name: "b")], root: "/Users/someone"
        )
        XCTAssertTrue(report.needingAttention.isEmpty)
        XCTAssertEqual(report.totalEntries, 6)
    }

    // MARK: - Explaining a refusal

    /// A consent-protected folder gets its own sentence, because the file mode
    /// a reader would go looking for is not what is stopping them.
    func testAConsentProtectedRefusalDoesNotBlameFilePermissions() {
        let explanation = FileIndexStatusReport.explanation(
            code: EPERM, isConsentProtected: true
        )
        XCTAssertTrue(explanation.contains("macOS"))
        XCTAssertFalse(explanation.lowercased().contains("file permissions"))
    }

    func testAnOrdinaryRefusalPointsAtFilePermissions() {
        XCTAssertTrue(
            FileIndexStatusReport
                .explanation(code: EACCES, isConsentProtected: false)
                .lowercased()
                .contains("permission")
        )
    }

    func testAnUnrecognisedCodeStillSaysSomething() {
        XCTAssertFalse(
            FileIndexStatusReport
                .explanation(code: nil, isConsentProtected: false)
                .isEmpty
        )
    }
}
