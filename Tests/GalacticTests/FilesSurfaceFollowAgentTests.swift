import AppKit
import XCTest

@testable import Galactic

/// Following an agent's directory, and the four ways of not following it.
///
/// The refusals are the substance. Re-rooting is one line; what took the
/// deciding was when *not* to — a reader mid-task, a reader who chose their own
/// root, and an agent that has not actually gone anywhere.
@MainActor
final class FilesSurfaceFollowAgentTests: XCTestCase {

    /// A host with one owner and a root it is told to answer with.
    ///
    /// Nothing here is exercised beyond `currentOwnerID` and `defaultRoot`; the
    /// rest is the protocol's price of admission.
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

    /// Bytes in memory, standing in for a host's file.
    private final class Store: FileSetStore {
        var saved: [String: PersistedFileSet] = [:]
        func save(_ state: PersistedFileSet, forOwner ownerID: String) {
            saved[ownerID] = state
        }
        func load(forOwner ownerID: String) -> PersistedFileSet? {
            saved[ownerID]
        }
    }

    private var dir: URL!
    private var host: Host!
    private var surface: FilesSurface!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `captureFocus` reads `NSApp`, which is nil until something asks for
        // the shared application.
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("follow-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        host = Host()
        host.root = try make("home")
        surface = FilesSurface(host: host)
        // What a mounted Files view does. `followAgentRoot` declines before the
        // set exists, so a test that skipped this would assert the refusal
        // rather than the behaviour it names.
        _ = surface.set(forOwner: host.currentOwnerID)
    }

    override func tearDownWithError() throws {
        FilePickerPresenter.shared.dismiss()
        FileSearchPresenter.shared.dismiss()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// A real directory, because `FilePaths.canonical` resolves through
    /// `realpath` and answers a path that does not exist with itself. Both
    /// answers are correct, and testing against the one Galaxy never produces
    /// would be testing the wrong branch.
    private func make(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    /// The picker up, without walking a corpus to get there. A nil root is what
    /// makes `buildIndex` return before it starts a walk.
    private func presentPicker() {
        FilePickerPresenter.shared.rootProvider = { nil }
        FilePickerPresenter.shared.present()
    }

    // MARK: - Following

    func testFollowingAnAgentThatMovedRerootsTheSet() throws {
        let moved = surface.followAgentRoot(to: try make("a"))

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
    }

    /// Asked twice for the same directory, the second ask is not a move. This
    /// is what makes entering the Files tab repeatedly harmless.
    func testFollowingTheSameAgentRootTwiceMovesNothing() throws {
        let a = try make("a")
        surface.followAgentRoot(to: a)

        let moved = surface.followAgentRoot(to: a)

        XCTAssertFalse(moved)
    }

    /// An agent that moved to where the reader already was records the move
    /// without reporting one — there is nothing to re-root.
    func testAnAgentMovingToTheCurrentRootRecordsWithoutMoving() throws {
        let a = try make("a")
        surface.changeRoot(to: a)

        let moved = surface.followAgentRoot(to: a)

        XCTAssertFalse(moved)
        XCTAssertEqual(
            surface.currentSet.lastFollowedAgentRoot, FilePaths.canonical(a)
        )
    }

    // MARK: - The reader's own root

    /// **The reader's own choice survives.** A root they browsed to differs
    /// from the agent's cwd for as long as they leave it there, so a comparison
    /// against the set's root would undo it on every visit.
    func testAReaderRerootIsNotUndoneWhileTheAgentStaysPut() throws {
        let a = try make("a")
        surface.followAgentRoot(to: a)
        surface.changeRoot(to: try make("elsewhere"))

        let moved = surface.followAgentRoot(to: a)

        XCTAssertFalse(moved)
        XCTAssertEqual(
            surface.currentSet.root.lastPathComponent, "elsewhere",
            "the agent has not moved, so the reader's root stands"
        )
    }

    /// And is undone once the agent does move, which is the requested behaviour
    /// rather than a concession.
    func testAReaderRerootYieldsOnceTheAgentMoves() throws {
        surface.followAgentRoot(to: try make("a"))
        surface.changeRoot(to: try make("elsewhere"))

        let moved = surface.followAgentRoot(to: try make("b"))

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "b")
    }

    // MARK: - An open panel

    /// A reader with the picker up is mid-task and must not be moved.
    func testAnOpenPanelRefusesTheFollow() throws {
        presentPicker()

        let moved = surface.followAgentRoot(to: try make("a"))

        XCTAssertFalse(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "home")
    }

    /// **The refusal must not consume the question.** Recording the agent root
    /// while declining to act on it would satisfy the comparison next time and
    /// lose the reset for good.
    func testARefusedFollowIsStillPendingOnceThePanelCloses() throws {
        let a = try make("a")
        presentPicker()
        surface.followAgentRoot(to: a)
        FilePickerPresenter.shared.dismiss()

        let moved = surface.followAgentRoot(to: a)

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
    }

    // MARK: - Before there is a set

    /// **The one refusal that is about losing work rather than interrupting
    /// it.** Asked before the owner's set exists, a follow would bring an empty
    /// set into being and persist it — writing that emptiness over the tabs
    /// still sitting on disk waiting for `restoreIfNeeded`.
    func testAFollowBeforeTheSetExistsWritesNothing() throws {
        let store = Store()
        store.save(
            PersistedFileSet(
                root: try make("saved").path,
                openPathRows: [["/one.swift"]],
                selectedPath: "/one.swift"
            ),
            forOwner: host.currentOwnerID
        )
        let fresh = FilesSurface(host: host, store: store)

        let moved = fresh.followAgentRoot(to: try make("a"))

        XCTAssertFalse(moved)
        XCTAssertEqual(
            store.load(forOwner: host.currentOwnerID)?.openPathRows,
            [["/one.swift"]],
            "the record still waiting to be restored is untouched"
        )
    }

    // MARK: - Across a relaunch

    /// A root chosen before quitting comes back, rather than being read as a
    /// move the moment the reader first opens Files again.
    ///
    /// The whole of what persisting the memory buys: restored without it, the
    /// nil answers "the agent has gone somewhere new" for an agent that has not
    /// moved at all, and the reader's root is gone on the first visit.
    func testAReaderRerootSurvivesARelaunchWithTheAgentStationary() throws {
        let store = Store()
        let agent = try make("a")
        let chosen = try make("elsewhere")
        let first = FilesSurface(host: host, store: store)
        _ = first.set(forOwner: host.currentOwnerID)
        first.followAgentRoot(to: agent)
        first.changeRoot(to: chosen)

        let second = FilesSurface(host: host, store: store)
        second.restoreIfNeeded(ownerID: host.currentOwnerID)
        let moved = second.followAgentRoot(to: agent)

        XCTAssertFalse(moved)
        XCTAssertEqual(second.currentSet.root.lastPathComponent, "elsewhere")
    }
}
