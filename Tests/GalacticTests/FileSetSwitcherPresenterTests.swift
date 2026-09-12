import AppKit
import XCTest

@testable import Galactic

/// The switcher's list, its naming card, and how it trades places with the
/// other cards in the Files surface.
@MainActor
final class FileSetSwitcherPresenterTests: XCTestCase {

    private var dir: URL!
    private var group: FileSetGroup!
    private var presenter: FileSetSwitcherPresenter!
    private var selected: [String] = []
    private var created: [String] = []
    private var deleted: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `ModalFocusCapture` reads `NSApp`, which is nil until something asks
        // for the shared application.
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("set-switcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        group = FileSetGroup(ownerID: "owner", defaultRoot: dir)
        selected = []
        created = []
        deleted = []
        presenter = FileSetSwitcherPresenter()
        presenter.groupProvider = { [unowned self] in self.group }
        presenter.onSelect = { [unowned self] id in
            self.selected.append(id)
            self.group.select(id: id)
        }
        presenter.onCreate = { [unowned self] name in
            switch self.group.create(name: name, root: self.dir) {
            case .failure(let problem):
                return problem
            case .success(let set):
                self.group.select(id: set.id)
                self.created.append(set.name)
                return nil
            }
        }
        presenter.onRename = { [unowned self] id, name in
            self.group.rename(id: id, to: name)
        }
        presenter.onDelete = { [unowned self] id in
            self.deleted.append(id)
            self.group.remove(id: id)
        }
    }

    override func tearDownWithError() throws {
        presenter.dismiss()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func make(_ name: String, origin: FileSet.Origin = .user) throws
        -> FileSet
    {
        try group.create(name: name, root: dir, origin: origin).get()
    }

    // MARK: - Presentation

    func testTheEscapeMonitorLivesExactlyAsLongAsTheCard() {
        presenter.present()
        XCTAssertTrue(presenter.isPresented)
        XCTAssertNotNil(presenter.focus.escapeMonitor)

        presenter.dismiss()

        XCTAssertFalse(presenter.isPresented)
        XCTAssertNil(presenter.focus.escapeMonitor)
    }

    func testTheModalRegisterCountsTheSwitcherAsAFilesPanel() {
        let switcher = FileSetSwitcherPresenter.shared
        switcher.groupProvider = { [unowned self] in self.group }
        defer {
            switcher.dismiss()
            switcher.groupProvider = { nil }
        }

        switcher.present()

        XCTAssertTrue(GalacticModals.isClaimingKeyboard)
        XCTAssertTrue(GalacticModals.filesPanelIsClaimingKeyboard)
    }

    func testThePickerAndTheSwitcherReplaceEachOther() {
        let picker = FilePickerPresenter.shared
        let switcher = FileSetSwitcherPresenter.shared
        picker.rootProvider = { nil }
        switcher.groupProvider = { [unowned self] in self.group }
        defer {
            switcher.dismiss()
            picker.dismiss()
            switcher.groupProvider = { nil }
        }

        picker.present()
        switcher.present()

        XCTAssertFalse(picker.isPresented)
        XCTAssertTrue(switcher.isPresented)

        picker.present()

        XCTAssertFalse(switcher.isPresented)
        XCTAssertTrue(picker.isPresented)
    }

    // MARK: - Rows

    func testTheListIsTheDefaultThenTheOtherSetsByNameThenANewSetRow() throws {
        try make("b")
        try make("a")

        presenter.present()

        XCTAssertEqual(
            presenter.rows.map(\.name), ["Default", "a", "b", "New set…"]
        )
        XCTAssertTrue(presenter.rows[0].isCurrent)
    }

    /// Choosing again goes back to the set the reader was just in.
    func testOpeningHighlightsTheSetShownBeforeThisOne() throws {
        let a = try make("a")
        let b = try make("b")
        group.select(id: a.id)
        group.select(id: b.id)

        presenter.present()

        XCTAssertEqual(presenter.rows[presenter.selectedIndex].setID, a.id)
    }

    func testWithNoSetBeforeTheFirstOneNotOnScreenIsHighlighted() throws {
        try make("a")

        presenter.present()

        XCTAssertEqual(presenter.selectedIndex, 1)
    }

    func testWithOnlyTheDefaultTheNewSetRowIsHighlighted() {
        presenter.present()

        XCTAssertEqual(presenter.rows.map(\.name), ["Default", "New set…"])
        XCTAssertEqual(presenter.selectedIndex, 1)
    }

    func testRowsCarryCountsAndWhoMadeTheSet() throws {
        let url = dir.appendingPathComponent("a.swift")
        try Data("one\n".utf8).write(to: url)
        let found = try make("found", origin: .agent)
        try found.open(url: url)
        found.addNote(
            filePath: url.path, startLine: 1, endLine: 1, lineContent: "one",
            content: "n", createdAt: "2026-09-12T00:00:00Z"
        )

        presenter.present()

        let row = try XCTUnwrap(presenter.rows.first { $0.name == "found" })
        XCTAssertEqual(row.fileCount, 1)
        XCTAssertEqual(row.noteCount, 1)
        XCTAssertTrue(row.isAgentMade)
    }

    func testTypingFiltersTheSetsAndOffersTheTypedName() throws {
        try make("auth flow")
        try make("billing")
        presenter.present()

        presenter.query = "auth"

        XCTAssertEqual(
            presenter.rows.map(\.name), ["auth flow", "New set “auth”"]
        )
        XCTAssertEqual(presenter.selectedIndex, 0)
    }

    func testANameThatIsAlreadyASetIsNotOfferedAgain() throws {
        try make("auth")
        presenter.present()

        presenter.query = "AUTH"

        XCTAssertEqual(presenter.rows.last?.name, "New set…")
    }

    // MARK: - Choosing

    func testReturnOnASetChoosesItAndCloses() throws {
        let a = try make("a")
        presenter.present()

        presenter.commit()

        XCTAssertEqual(selected, [a.id])
        XCTAssertFalse(presenter.isPresented)
    }

    // MARK: - Making

    func testTheNewSetRowWithNothingTypedAsksForAName() throws {
        presenter.present()

        presenter.activate(try XCTUnwrap(presenter.rows.last))

        XCTAssertEqual(presenter.mode, .create)
        XCTAssertTrue(presenter.isPresented)
        XCTAssertTrue(created.isEmpty)
    }

    func testTheNewSetRowWithAFreeNameTypedMakesTheSet() throws {
        presenter.present()
        presenter.query = "auth"

        presenter.activate(try XCTUnwrap(presenter.rows.last))

        XCTAssertEqual(created, ["auth"])
        XCTAssertFalse(presenter.isPresented)
    }

    func testATakenNameStaysInTheCardWithTheProblem() {
        presenter.present()
        presenter.beginCreate()
        presenter.nameText = "default"

        presenter.submitName()

        XCTAssertEqual(presenter.nameProblem, .taken("Default"))
        XCTAssertEqual(presenter.mode, .create)
        XCTAssertTrue(presenter.isPresented)
        XCTAssertTrue(created.isEmpty)
    }

    func testEditingTheNameClearsTheProblem() {
        presenter.present()
        presenter.beginCreate()
        presenter.nameText = "default"
        presenter.submitName()

        presenter.nameText = "defaults"

        XCTAssertNil(presenter.nameProblem)
    }

    func testEscapeUnwindsNamingThenTheList() {
        presenter.present()
        presenter.beginCreate()

        presenter.escape()

        XCTAssertEqual(presenter.mode, .list)
        XCTAssertTrue(presenter.isPresented)

        presenter.escape()

        XCTAssertFalse(presenter.isPresented)
    }

    // MARK: - Renaming and deleting

    func testRenamingStartsFromTheNameAndReturnsToTheList() throws {
        let auth = try make("auth")
        presenter.present()

        presenter.beginRename(setID: auth.id)
        XCTAssertEqual(presenter.nameText, "auth")
        XCTAssertEqual(presenter.namingTitle, "Rename “auth”")

        presenter.nameText = "auth flow"
        presenter.submitName()

        XCTAssertEqual(auth.name, "auth flow")
        XCTAssertEqual(presenter.mode, .list)
        XCTAssertTrue(presenter.rows.contains { $0.name == "auth flow" })
    }

    func testTheDefaultOffersNoRename() {
        presenter.present()

        presenter.beginRename(setID: group.defaultSet.id)

        XCTAssertEqual(presenter.mode, .list)
    }

    func testDeletingReachesTheSurface() throws {
        let a = try make("a")
        presenter.present()

        presenter.delete(setID: a.id)

        XCTAssertEqual(deleted, [a.id])
    }

    /// An owner change under an open card closes it rather than acting on the
    /// sets of a session nobody is looking at.
    func testAnOwnerChangeUnderTheCardClosesIt() throws {
        let a = try make("a")
        presenter.present()
        let other = FileSetGroup(ownerID: "other", defaultRoot: dir)
        presenter.groupProvider = { other }

        presenter.activate(
            try XCTUnwrap(presenter.rows.first { $0.setID == a.id })
        )

        XCTAssertTrue(selected.isEmpty)
        XCTAssertFalse(presenter.isPresented)
    }
}
