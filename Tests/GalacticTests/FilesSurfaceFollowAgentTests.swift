import AppKit
import XCTest

@testable import Galactic

/// Following an agent's directory, and the three ways of not following it.
///
/// The refusals are the substance. Re-rooting is one line; what took the
/// deciding was when *not* to — a reader mid-task, a set that does not exist
/// yet, and an agent that is already where the reader is.
///
/// A root the reader chose is deliberately *not* among them: arriving at the
/// surface resets it, and keeping one across a visit elsewhere is what leaving
/// a panel open is for.
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
        LineJumpPresenter.shared.dismiss()
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

    private func presentSearcher() {
        FileSearchPresenter.shared.rootProvider = { nil }
        FileSearchPresenter.shared.present()
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

    /// An agent already where the reader is moves nothing.
    func testAnAgentAtTheCurrentRootMovesNothing() throws {
        let a = try make("a")
        surface.changeRoot(to: a)

        let moved = surface.followAgentRoot(to: a)

        XCTAssertFalse(moved)
    }

    // MARK: - The reader's own root

    /// **A root the reader chose does not survive the next arrival.** Compared
    /// against the set's own root, so an agent that never moves is still
    /// followed every time — which the memory this replaced made impossible,
    /// since it matched from the first arrival onward and the follow fired
    /// exactly once for the life of a session.
    func testAReaderRerootIsUndoneOnTheNextArrival() throws {
        let a = try make("a")
        surface.followAgentRoot(to: a)
        surface.changeRoot(to: try make("elsewhere"))

        let moved = surface.followAgentRoot(to: a)

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
    }

    /// And equally when the agent has moved on in the meantime.
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

    /// A root chosen before quitting comes back with the set, and then yields
    /// on the first arrival — a relaunch is an arrival like any other.
    ///
    /// The tabs that came back with it are untouched: re-rooting moves where
    /// browsing starts, not what is open.
    func testARestoredRootYieldsToTheAgentOnTheFirstArrival() throws {
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

        XCTAssertTrue(moved)
        XCTAssertEqual(second.currentSet.root.lastPathComponent, "a")
    }

    // MARK: - Leaving and coming back

    /// **A panel left open is the escape hatch**, and the only one. A reader
    /// who wants a root to survive a trip to another tab does not close the
    /// picker before going.
    func testAPanelLeftOpenSurvivesTheRoundTripAndBlocksTheReroot() throws {
        let chosen = try make("elsewhere")
        surface.changeRoot(to: chosen)
        presentPicker()

        surface.leaveFilesSurface()
        XCTAssertFalse(
            FilePickerPresenter.shared.isPresented,
            "the panel goes down while the surface is away, so nothing "
                + "invisible holds the keyboard"
        )

        let moved = surface.enterFilesSurface(agentRoot: try make("a"))

        XCTAssertFalse(moved)
        XCTAssertTrue(FilePickerPresenter.shared.isPresented)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "elsewhere")
    }

    /// With nothing open, coming back is a plain arrival.
    func testComingBackWithNoPanelRerootsToTheAgent() throws {
        surface.changeRoot(to: try make("elsewhere"))

        let moved = surface.enterFilesSurface(agentRoot: try make("a"))

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    /// The hatch is spent once used, so a second trip with nothing open
    /// re-roots like any other arrival.
    func testTheHatchIsNotReusedOnTheNextTrip() throws {
        surface.changeRoot(to: try make("elsewhere"))
        presentPicker()
        surface.leaveFilesSurface()
        surface.enterFilesSurface(agentRoot: try make("a"))
        FilePickerPresenter.shared.dismiss()

        surface.leaveFilesSurface()
        let moved = surface.enterFilesSurface(agentRoot: try make("a"))

        XCTAssertTrue(moved)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
    }

    /// The searcher is a rooted surface too — it reads the same set root, and
    /// its own root field can move it — so it gets the same hatch.
    func testTheSearcherLeftOpenAlsoSurvivesAndBlocksTheReroot() throws {
        surface.changeRoot(to: try make("elsewhere"))
        presentSearcher()

        surface.leaveFilesSurface()
        XCTAssertFalse(FileSearchPresenter.shared.isPresented)

        let moved = surface.enterFilesSurface(agentRoot: try make("a"))

        XCTAssertFalse(moved)
        XCTAssertTrue(FileSearchPresenter.shared.isPresented)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "elsewhere")
    }

    /// **The line jump goes down with the rest and is not put back.** It holds
    /// an armed Escape monitor like the other two, so leaving it presented
    /// behind an unwatched surface is the same defect — but it is about the
    /// open document rather than about a root, so arriving re-roots as usual.
    func testTheLineJumpIsDismissedAndDoesNotBlockTheReroot() throws {
        surface.changeRoot(to: try make("elsewhere"))
        LineJumpPresenter.shared.present()

        surface.leaveFilesSurface()
        XCTAssertFalse(LineJumpPresenter.shared.isPresented)

        let moved = surface.enterFilesSurface(agentRoot: try make("a"))

        XCTAssertTrue(moved)
        XCTAssertFalse(LineJumpPresenter.shared.isPresented)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "a")
    }

    /// A host with no agent to follow leaves the root alone, and still gets its
    /// panel back.
    func testAHostWithNoAgentRootKeepsItsRootAndItsPanel() throws {
        surface.changeRoot(to: try make("elsewhere"))
        presentPicker()
        surface.leaveFilesSurface()

        let moved = surface.enterFilesSurface(agentRoot: nil)

        XCTAssertFalse(moved)
        XCTAssertTrue(FilePickerPresenter.shared.isPresented)
        XCTAssertEqual(surface.currentSet.root.lastPathComponent, "elsewhere")
    }
}
