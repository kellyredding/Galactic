import AppKit
import XCTest

@testable import Galactic

/// Choosing, making and removing sets through the surface, and what each one
/// writes down.
@MainActor
final class FilesSurfaceSetsTests: XCTestCase {

    private final class Host: FilesHost {
        var currentOwnerID = "owner"
        var root: URL = URL(fileURLWithPath: "/")

        func defaultRoot(forOwner ownerID: String) -> URL { root }
        func showFilesSurface() {}
        func showAgentSurface() {}
        func deliverReview(_ review: String, forOwner ownerID: String) {}
        var textEntryPayload: [String: [[String: Any]]]? { nil }
        var searchContextLines: Int { 2 }
    }

    private final class Store: FileSetStore {
        var saved: [String: PersistedFileSetGroup] = [:]
        func save(_ group: PersistedFileSetGroup, forOwner ownerID: String) {
            saved[ownerID] = group
        }
        func load(forOwner ownerID: String) -> PersistedFileSetGroup? {
            saved[ownerID]
        }
    }

    private static let run = FileSearchRun(
        query: FileSearchQuery(
            text: "x", isCaseSensitive: false, contextLines: 2
        ),
        root: "/",
        files: [],
        filesConsidered: 0,
        filesScanned: 0,
        matchCount: 0,
        truncation: nil,
        skippedNames: []
    )

    private var dir: URL!
    private var host: Host!
    private var store: Store!
    private var surface: FilesSurface!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        // A new set offers the picker; a nil root keeps it from walking a tree.
        FilePickerPresenter.shared.rootProvider = { nil }
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-sets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        host = Host()
        host.root = dir
        store = Store()
        surface = FilesSurface(host: host, store: store)
    }

    override func tearDownWithError() throws {
        FilePickerPresenter.shared.dismiss()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("one\n".utf8).write(to: url)
        return url
    }

    private func make(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    // MARK: - Making

    func testANewSetIsShownAndWrittenDown() throws {
        XCTAssertNil(surface.createSet(named: "auth"))

        XCTAssertEqual(surface.currentSet.name, "auth")
        let saved = try XCTUnwrap(store.load(forOwner: "owner"))
        XCTAssertEqual(saved.sets.map(\.name), ["Default", "auth"])
        XCTAssertEqual(saved.selectedID, surface.currentSet.id)
    }

    func testANewSetOffersThePicker() {
        surface.createSet(named: "auth")

        XCTAssertTrue(FilePickerPresenter.shared.isPresented)
    }

    func testANewSetStartsWhereTheSetOnScreenIsBrowsing() throws {
        let elsewhere = try make("elsewhere")
        surface.changeRoot(to: elsewhere)

        surface.createSet(named: "auth")

        XCTAssertEqual(surface.currentSet.root, elsewhere)
    }

    func testATakenNameIsReportedAndNothingChanges() {
        XCTAssertEqual(surface.createSet(named: "default"), .taken("Default"))

        XCTAssertTrue(surface.currentSet.isDefault)
        XCTAssertNil(store.load(forOwner: "owner"))
    }

    // MARK: - Choosing

    func testChoosingASetIsWrittenDownAndReported() {
        var reported: [String] = []
        surface.onSelectionChanged = { reported.append($0.id) }
        surface.createSet(named: "auth")
        let auth = surface.currentSet
        let base = surface.currentGroup.defaultSet

        surface.selectSet(id: base.id)

        XCTAssertEqual(reported, [auth.id, base.id])
        XCTAssertEqual(store.load(forOwner: "owner")?.selectedID, base.id)
    }

    /// A set changing behind the one on screen is not what the reader is
    /// looking at, so it is written down without being reported.
    func testAChangeToASetNotOnScreenIsNotReportedAsTheSelection() {
        surface.createSet(named: "auth")
        var reported: [String] = []
        surface.onSelectionChanged = { reported.append($0.id) }

        surface.persist(surface.currentGroup.defaultSet)

        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - Renaming

    func testRenamingIsWrittenDownAndAClashIsReported() {
        surface.createSet(named: "auth")
        surface.createSet(named: "billing")
        let billing = surface.currentSet

        XCTAssertEqual(
            surface.renameSet(id: billing.id, to: "Auth"), .taken("auth")
        )
        XCTAssertNil(surface.renameSet(id: billing.id, to: "payments"))
        XCTAssertEqual(
            store.load(forOwner: "owner")?.sets.map(\.name).sorted(),
            ["Default", "auth", "payments"]
        )
    }

    // MARK: - Deleting

    func testTheDefaultCannotBeDeleted() {
        surface.deleteSet(id: surface.currentGroup.defaultSet.id)

        XCTAssertEqual(surface.currentGroup.sets.count, 1)
    }

    func testDeletingTheSetOnScreenShowsTheDefault() {
        surface.createSet(named: "auth")
        let auth = surface.currentSet

        surface.deleteSet(id: auth.id)

        XCTAssertTrue(surface.currentSet.isDefault)
        XCTAssertNil(surface.currentGroup.set(withID: auth.id))
        XCTAssertEqual(store.load(forOwner: "owner")?.sets.count, 1)
    }

    func testDeletingASetDropsItsResults() {
        surface.createSet(named: "auth")
        let auth = surface.currentSet
        surface.searchRuns[auth.id] = Self.run

        surface.deleteSet(id: auth.id)

        XCTAssertNil(surface.searchRuns[auth.id])
    }

    // MARK: - Results

    func testEachSetHasItsOwnResultsFile() {
        surface.createSet(named: "auth")
        let group = surface.currentGroup

        XCTAssertNotEqual(
            FilesSurface.searchResultsURL(setID: group.defaultSet.id),
            FilesSurface.searchResultsURL(setID: group.selected.id)
        )
    }

    func testAResultsRunIsFoundOnlyThroughItsOwnSet() {
        surface.createSet(named: "auth")
        let group = surface.currentGroup
        let path = FilesSurface.searchResultsURL(setID: group.selected.id).path
        surface.searchRuns[group.selected.id] = Self.run

        XCTAssertNotNil(surface.searchRun(forPath: path, setID: group.selected.id))
        XCTAssertNil(surface.searchRun(forPath: path, setID: group.defaultSet.id))
    }

    // MARK: - Following the agent

    func testTheAgentMovesTheDefaultEvenWhileAnotherSetIsShowing() throws {
        surface.createSet(named: "auth")
        // The new set offered the picker, and an open panel refuses a follow.
        FilePickerPresenter.shared.dismiss()

        XCTAssertTrue(surface.followAgentRoot(to: try make("agent")))

        XCTAssertEqual(
            surface.currentGroup.defaultSet.root.lastPathComponent, "agent"
        )
        XCTAssertEqual(surface.currentSet.root, dir, "auth keeps its root")
    }

    // MARK: - Across a relaunch

    func testSetsComeBackWithTheirNamesIdsAndTheSelection() throws {
        let url = try write("a.swift")
        surface.createSet(named: "auth")
        FilePickerPresenter.shared.dismiss()
        surface.open(url: url)
        let auth = surface.currentSet

        let relaunched = FilesSurface(host: host, store: store)
        relaunched.restoreIfNeeded(ownerID: "owner")

        let group = relaunched.currentGroup
        XCTAssertEqual(group.sets.map(\.name), ["Default", "auth"])
        XCTAssertEqual(group.selected.id, auth.id)
        XCTAssertEqual(group.selected.selectedPath, url.path)
    }
}
