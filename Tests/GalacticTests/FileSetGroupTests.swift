import XCTest

@testable import Galactic

/// One owner's sets: which is showing, what they are called, and how they come
/// back from a saved record.
final class FileSetGroupTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-set-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("one\ntwo\n".utf8).write(to: url)
        return url
    }

    private func makeGroup() -> FileSetGroup {
        FileSetGroup(ownerID: "owner", defaultRoot: dir)
    }

    @discardableResult
    private func create(_ name: String, in group: FileSetGroup) throws
        -> FileSet
    {
        try group.create(name: name, root: dir).get()
    }

    private func custom(
        id: String, name: String, root: String? = nil,
        rows: [[String]] = [], selected: String? = nil
    ) -> PersistedFileSet {
        PersistedFileSet(
            id: id, name: name, isDefault: false,
            root: root ?? dir.path, openPathRows: rows, selectedPath: selected
        )
    }

    // MARK: - The default

    func testANewGroupHoldsOnlyTheDefaultAndShowsIt() {
        let group = makeGroup()

        XCTAssertEqual(group.sets.count, 1)
        XCTAssertTrue(group.defaultSet.isDefault)
        XCTAssertEqual(group.defaultSet.name, "Default")
        XCTAssertEqual(
            group.defaultSet.id, FileSetGroup.defaultSetID(forOwner: "owner")
        )
        XCTAssertTrue(group.selected === group.defaultSet)
    }

    func testTheDefaultKeepsItsName() {
        let group = makeGroup()

        XCTAssertEqual(
            group.rename(id: group.defaultSet.id, to: "Mine"), .unchangeable
        )
        XCTAssertEqual(group.defaultSet.name, "Default")
    }

    func testTheDefaultCannotBeRemoved() {
        let group = makeGroup()

        XCTAssertNil(group.remove(id: group.defaultSet.id))
        XCTAssertEqual(group.sets.count, 1)
    }

    // MARK: - Making and choosing

    func testANewSetIsAddedWithoutBeingShown() throws {
        let group = makeGroup()

        let auth = try create("auth", in: group)

        XCTAssertTrue(group.selected.isDefault)
        XCTAssertEqual(group.sets.map(\.id), [group.defaultSet.id, auth.id])
        XCTAssertEqual(auth.origin, .user)
        XCTAssertFalse(auth.isDefault)
        XCTAssertEqual(auth.root, dir)
    }

    /// The way Finder sorts, so a number in a name is read as a number.
    func testTheOtherSetsFollowTheDefaultByName() throws {
        let group = makeGroup()
        for name in ["test10", "beta", "test2", "Alpha"] {
            try create(name, in: group)
        }

        XCTAssertEqual(
            group.sets.map(\.name),
            ["Default", "Alpha", "beta", "test2", "test10"]
        )
    }

    func testChoosingASetLeavesTheOrderAlone() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        let b = try create("b", in: group)

        XCTAssertTrue(group.select(id: b.id))

        XCTAssertTrue(group.selected === b)
        XCTAssertEqual(group.sets.map(\.id), [group.defaultSet.id, a.id, b.id])
    }

    func testChoosingASetRemembersTheOneBefore() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        let b = try create("b", in: group)

        group.select(id: a.id)
        group.select(id: b.id)

        XCTAssertEqual(group.previousID, a.id)
    }

    func testChoosingTheSetOnScreenForgetsNothing() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        group.select(id: a.id)

        group.select(id: a.id)

        XCTAssertEqual(group.previousID, group.defaultSet.id)
    }

    func testChoosingAnUnknownSetChangesNothing() {
        let group = makeGroup()

        XCTAssertFalse(group.select(id: "nope"))
        XCTAssertTrue(group.selected.isDefault)
    }

    // MARK: - Names

    func testANameIsTrimmed() throws {
        let group = makeGroup()

        XCTAssertEqual(try create("  auth flow \n", in: group).name, "auth flow")
    }

    func testAnEmptyNameIsRefused() {
        XCTAssertEqual(makeGroup().validateName("   "), .failure(.empty))
    }

    func testANameInUseIsRefusedWhateverItsCaseAndSpacing() throws {
        let group = makeGroup()
        try create("Auth", in: group)

        XCTAssertEqual(group.validateName(" auth "), .failure(.taken("Auth")))
    }

    func testTheDefaultsNameIsTaken() {
        XCTAssertEqual(
            makeGroup().validateName("default"), .failure(.taken("Default"))
        )
    }

    func testASetMayBeRenamedToItsOwnNameInAnotherCase() throws {
        let group = makeGroup()
        let auth = try create("auth", in: group)

        XCTAssertNil(group.rename(id: auth.id, to: "AUTH"))
        XCTAssertEqual(auth.name, "AUTH")
    }

    func testRenamingIntoAnotherSetsNameIsRefused() throws {
        let group = makeGroup()
        try create("billing", in: group)
        let auth = try create("auth", in: group)

        XCTAssertEqual(
            group.rename(id: auth.id, to: "Billing"), .taken("billing")
        )
        XCTAssertEqual(auth.name, "auth")
    }

    func testRenamingMovesASetToItsPlaceByName() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        try create("m", in: group)

        group.rename(id: a.id, to: "z")

        XCTAssertEqual(group.sets.map(\.name), ["Default", "m", "z"])
    }

    func testFindingASetByNameIgnoresCaseAndSpacing() throws {
        let group = makeGroup()
        let auth = try create("Auth Flow", in: group)

        XCTAssertTrue(group.set(named: " auth flow") === auth)
    }

    // MARK: - Removing

    func testRemovingTheSetOnScreenShowsTheDefault() throws {
        let group = makeGroup()
        let auth = try create("auth", in: group)
        group.select(id: auth.id)

        XCTAssertTrue(group.remove(id: auth.id) === auth)

        XCTAssertTrue(group.selected.isDefault)
        XCTAssertEqual(group.sets.count, 1)
    }

    func testRemovingAnotherSetLeavesTheSelectionAlone() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        let b = try create("b", in: group)
        group.select(id: a.id)

        group.remove(id: b.id)

        XCTAssertTrue(group.selected === a)
    }

    func testRemovingTheSetShownBeforeForgetsIt() throws {
        let group = makeGroup()
        let a = try create("a", in: group)
        let b = try create("b", in: group)
        group.select(id: a.id)
        group.select(id: b.id)

        group.remove(id: a.id)

        XCTAssertNil(group.previousID)
    }

    // MARK: - Notes

    func testNotesAreReportedForSetsNotOnScreen() throws {
        let group = makeGroup()
        let url = try write("a.swift")
        let auth = try create("auth", in: group)
        try auth.open(url: url)
        auth.addNote(
            filePath: url.path, startLine: 1, endLine: 1, lineContent: "one",
            content: "n", createdAt: "2026-09-12T00:00:00Z"
        )

        XCTAssertTrue(group.otherSetsHoldNotes, "auth is not on screen")
        XCTAssertEqual(group.pendingNoteCount, 1)

        group.select(id: auth.id)

        XCTAssertFalse(group.otherSetsHoldNotes, "the only notes are on screen")
    }

    // MARK: - Restoring

    /// A view may already observe the default before a restore runs, so the
    /// restore goes into that object rather than replacing it.
    func testTheDefaultIsRestoredInPlace() throws {
        let group = makeGroup()
        let original = group.defaultSet
        let url = try write("a.swift")
        let elsewhere = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true
        )

        group.restore(
            from: PersistedFileSetGroup(
                sets: [
                    PersistedFileSet(
                        id: original.id, name: "Default", isDefault: true,
                        root: elsewhere.path, openPathRows: [[url.path]],
                        selectedPath: url.path
                    )
                ],
                selectedID: original.id
            )
        )

        XCTAssertTrue(group.defaultSet === original)
        XCTAssertEqual(original.root.path, elsewhere.path)
        XCTAssertEqual(original.selectedPath, url.path)
    }

    func testCustomSetsComeBackWithTheirIdsNamesOriginsAndFiles() throws {
        let group = makeGroup()
        let url = try write("a.swift")
        var agentMade = custom(
            id: "set-1", name: "auth", rows: [[url.path]], selected: url.path
        )
        agentMade.origin = .agent

        group.restore(
            from: PersistedFileSetGroup(
                sets: [
                    PersistedFileSet(
                        root: dir.path, openPathRows: [], selectedPath: nil
                    ),
                    agentMade,
                ],
                selectedID: "set-1"
            )
        )

        let auth = try XCTUnwrap(group.set(withID: "set-1"))
        XCTAssertEqual(auth.name, "auth")
        XCTAssertEqual(auth.origin, .agent)
        XCTAssertEqual(auth.selectedPath, url.path)
        XCTAssertTrue(group.selected === auth)
        XCTAssertEqual(group.sets.map(\.id), [group.defaultSet.id, "set-1"])
    }

    func testASelectionThatIsGoneFallsBackToTheDefault() {
        let group = makeGroup()

        group.restore(from: PersistedFileSetGroup(sets: [], selectedID: "gone"))

        XCTAssertTrue(group.selected.isDefault)
    }

    /// A record written before sets had names was its owner's only set.
    func testALoneRecordFromBeforeSetsIsTheDefault() throws {
        let group = makeGroup()
        let url = try write("a.swift")

        group.restore(
            from: PersistedFileSetGroup(
                sets: [
                    PersistedFileSet(
                        root: dir.path, openPathRows: [[url.path]],
                        selectedPath: url.path
                    )
                ],
                selectedID: nil
            )
        )

        XCTAssertEqual(group.sets.count, 1)
        XCTAssertEqual(group.defaultSet.selectedPath, url.path)
    }

    func testRecordsThatCannotBeTrustedAreSkipped() {
        let group = makeGroup()

        group.restore(
            from: PersistedFileSetGroup(
                sets: [
                    custom(id: "", name: "no id"),
                    custom(id: "a", name: "  "),
                    custom(id: "b", name: "auth"),
                    custom(id: "c", name: "AUTH"),
                    custom(id: "b", name: "billing"),
                    custom(id: "d", name: "default"),
                ],
                selectedID: nil
            )
        )

        XCTAssertEqual(group.sets.map(\.id), [group.defaultSet.id, "b"])
    }

    func testRestoredSetsAreOrderedByName() {
        let group = makeGroup()

        group.restore(
            from: PersistedFileSetGroup(
                sets: [
                    custom(id: "z", name: "zeta"),
                    custom(id: "a", name: "alpha"),
                ],
                selectedID: nil
            )
        )

        XCTAssertEqual(group.sets.map(\.name), ["Default", "alpha", "zeta"])
    }

    func testACustomSetWithNoRootStartsWhereTheDefaultDoes() {
        let group = makeGroup()

        group.restore(
            from: PersistedFileSetGroup(
                sets: [custom(id: "a", name: "auth", root: "")],
                selectedID: nil
            )
        )

        XCTAssertEqual(group.set(withID: "a")?.root, group.defaultSet.root)
    }
}
