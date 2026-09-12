import AppKit
import XCTest

@testable import Galactic

/// What an agent may do with an owner's sets, and what it is told back.
@MainActor
final class FilesSurfaceAgentTests: XCTestCase {

    private final class Host: FilesHost {
        var currentOwnerID = "owner"
        var root: URL = URL(fileURLWithPath: "/")
        var shown = 0

        func defaultRoot(forOwner ownerID: String) -> URL { root }
        func showFilesSurface() { shown += 1 }
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

    private var dir: URL!
    private var host: Host!
    private var store: Store!
    private var surface: FilesSurface!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        // A nil root keeps a presented picker from walking a tree.
        FilePickerPresenter.shared.rootProvider = { nil }
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-agent-\(UUID().uuidString)")
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

    @discardableResult
    private func perform(
        _ request: FileSetAgentRequest, owner: String = "owner"
    ) -> FileSetAgentReply {
        surface.perform(request, forOwner: owner)
    }

    private func json(_ reply: FileSetAgentReply) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: reply.jsonData())
                as? [String: Any]
        )
    }

    private var group: FileSetGroup { surface.group(forOwner: "owner") }

    // MARK: - Parsing

    func testEachRequestIsReadFromItsEventAndDetail() {
        func parse(_ event: String, _ detail: [String: Any]? = nil)
            -> FileSetAgentRequest?
        {
            guard
                case .success(let request)? = FileSetAgentRequest.parse(
                    event: event, detail: detail
                )
            else { return nil }
            return request
        }

        XCTAssertEqual(parse("file_set.list"), .list)
        XCTAssertEqual(
            parse("file_set.view", ["name": "auth"]), .view(name: "auth")
        )
        XCTAssertEqual(
            parse("file_set.open", ["name": "auth", "paths": ["/a", "/b"]]),
            .open(name: "auth", paths: ["/a", "/b"])
        )
        XCTAssertEqual(
            parse("file_set.show", ["name": "auth"]), .show(name: "auth")
        )
        XCTAssertEqual(
            parse("file_set.rename", ["name": "auth", "new_name": "login"]),
            .rename(name: "auth", to: "login")
        )
        XCTAssertEqual(
            parse("file_set.remove", ["name": "auth"]), .remove(name: "auth")
        )
    }

    func testAnyOtherEventIsLeftForTheHost() {
        XCTAssertNil(
            FileSetAgentRequest.parse(
                event: "scratch.add", detail: ["name": "auth"]
            )
        )
    }

    func testAMalformedRequestIsAnsweredWithWhatIsWrong() {
        func failure(_ event: String, _ detail: [String: Any]?) -> String? {
            guard
                case .failure(let failure)? = FileSetAgentRequest.parse(
                    event: event, detail: detail
                )
            else { return nil }
            return failure.message
        }

        XCTAssertEqual(
            failure("file_set.view", nil),
            "The request is missing its set name."
        )
        XCTAssertEqual(
            failure("file_set.show", ["name": "  "]),
            "The request is missing its set name."
        )
        XCTAssertEqual(
            failure("file_set.rename", ["name": "auth"]),
            "The request is missing its new name."
        )
        XCTAssertEqual(
            failure("file_set.open", ["name": "auth", "paths": [String]()]),
            "The request is missing its files to open."
        )
        XCTAssertEqual(
            failure("file_set.open", ["name": "auth", "paths": ["/a", 3] as [Any]]),
            "The request's files to open are not all paths."
        )
        XCTAssertEqual(
            failure("file_set.close", [:]),
            "There is no file-set request called “close”."
        )
    }

    // MARK: - Reading

    func testListingDescribesEverySet() throws {
        let object = try json(perform(.list))

        XCTAssertEqual(object["ok"] as? Bool, true)
        let sets = try XCTUnwrap(object["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(
            sets[0]["id"] as? String,
            FileSetGroup.defaultSetID(forOwner: "owner")
        )
        XCTAssertEqual(sets[0]["name"] as? String, "Default")
        XCTAssertEqual(sets[0]["default"] as? Bool, true)
        XCTAssertEqual(sets[0]["origin"] as? String, "user")
        XCTAssertEqual(sets[0]["files"] as? Int, 0)
        XCTAssertEqual(sets[0]["notes"] as? Int, 0)
        XCTAssertEqual(sets[0]["selected"] as? Bool, true)
    }

    func testViewingListsTheFilesInTabOrderWithTheirNotes() throws {
        let a = try write("a.swift")
        let b = try write("b.swift")
        perform(.open(name: "auth", paths: [a.path, b.path]))
        let auth = try XCTUnwrap(group.set(named: "auth"))
        auth.addNote(
            filePath: b.path, startLine: 1, endLine: 1,
            lineContent: "one", content: "why", createdAt: "now"
        )

        let object = try json(perform(.view(name: "AUTH")))

        XCTAssertEqual(object["root"] as? String, dir.path)
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["path"] as? String }, [a.path, b.path])
        XCTAssertEqual(files.map { $0["notes"] as? Int }, [0, 1])
        XCTAssertEqual(files.map { $0["selected"] as? Bool }, [true, false])
        XCTAssertEqual((object["set"] as? [String: Any])?["notes"] as? Int, 1)
    }

    func testTheDefaultSetCanBeReadLikeAnyOther() throws {
        let object = try json(perform(.view(name: "default")))

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(
            (object["set"] as? [String: Any])?["default"] as? Bool, true
        )
    }

    func testAnUnknownSetIsNamedInTheRefusal() throws {
        let object = try json(perform(.show(name: "nope")))

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "There is no set named “nope”.")
        XCTAssertNil(object["message"])
    }

    func testTheSearchResultsAreNotAFileTheAgentIsShown() throws {
        setenv("GALACTIC_HOME", dir.appendingPathComponent("home").path, 1)
        defer { unsetenv("GALACTIC_HOME") }
        perform(.list)
        let base = group.defaultSet
        let results = FilesSurface.searchResultsURL(setID: base.id)
        try FileManager.default.createDirectory(
            at: results.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("results\n".utf8).write(to: results)
        try base.open(url: results)

        let object = try json(perform(.view(name: "Default")))

        XCTAssertEqual((object["files"] as? [Any])?.count, 0)
        XCTAssertEqual((object["set"] as? [String: Any])?["files"] as? Int, 0)
    }

    // MARK: - Opening

    func testOpeningMakesASetOfItsOwnAndPutsItOnScreen() throws {
        let a = try write("a.swift")
        let b = try write("b.swift")

        let reply = perform(.open(name: "auth", paths: [a.path, b.path]))

        XCTAssertTrue(reply.isSuccess)
        XCTAssertEqual(
            reply.message,
            "Made “auth” and opened 2 files in it. It is on screen."
        )
        let auth = try XCTUnwrap(group.set(named: "auth"))
        XCTAssertEqual(auth.origin, .agent)
        XCTAssertEqual(group.selectedID, auth.id)
        XCTAssertEqual(auth.tabs.tabs.map(\.path), [a.path, b.path])
        XCTAssertEqual(auth.selectedPath, a.path, "a batch is read from its start")
        XCTAssertEqual(host.shown, 1)
        XCTAssertTrue(group.defaultSet.isEmpty, "the user's own set is untouched")

        let saved = try XCTUnwrap(store.load(forOwner: "owner"))
        XCTAssertEqual(saved.selectedID, auth.id)
        XCTAssertEqual(saved.sets.first { $0.name == "auth" }?.origin, .agent)
    }

    func testOpeningIntoAnExistingSetOnlyAddsTabs() throws {
        let a = try write("a.swift")
        let b = try write("b.swift")
        let c = try write("c.swift")
        perform(.open(name: "auth", paths: [a.path]))

        let object = try json(
            perform(
                .open(name: "Auth", paths: [b.path, a.path, c.path, b.path])
            )
        )

        let auth = try XCTUnwrap(group.set(named: "auth"))
        XCTAssertEqual(
            Set(auth.tabs.tabs.map(\.path)), [a.path, b.path, c.path]
        )
        XCTAssertEqual(auth.selectedPath, b.path)
        XCTAssertEqual(object["created"] as? Bool, false)
        XCTAssertEqual(object["opened"] as? [String], [b.path, c.path])
        XCTAssertEqual(object["already_open"] as? [String], [a.path])
        XCTAssertEqual(
            object["message"] as? String,
            "Opened 2 files in “auth”. 1 more was already open. It is on screen."
        )
    }

    func testOpeningOnlyWhatIsAlreadyOpenSaysSo() throws {
        let a = try write("a.swift")
        perform(.open(name: "auth", paths: [a.path]))

        XCTAssertEqual(
            perform(.open(name: "auth", paths: [a.path])).message,
            "Nothing new to open: 1 file was already open in “auth”. It is on "
                + "screen."
        )
    }

    func testASetTheUserMadeCanBeOpenedInto() throws {
        let a = try write("a.swift")
        surface.createSet(named: "mine")
        FilePickerPresenter.shared.dismiss()

        XCTAssertTrue(perform(.open(name: "mine", paths: [a.path])).isSuccess)

        let mine = try XCTUnwrap(group.set(named: "mine"))
        XCTAssertEqual(mine.origin, .user, "opening into it does not claim it")
        XCTAssertEqual(mine.tabs.tabs.map(\.path), [a.path])
    }

    func testTheDefaultSetIsTheUsersOwn() throws {
        let a = try write("a.swift")

        for request: FileSetAgentRequest in [
            .open(name: "Default", paths: [a.path]),
            .rename(name: "default", to: "mine"),
            .remove(name: "DEFAULT"),
        ] {
            let reply = perform(request)
            XCTAssertFalse(reply.isSuccess)
            XCTAssertEqual(
                reply.message, FileSetAgentFailure.defaultIsUsers.message
            )
        }

        XCTAssertTrue(group.defaultSet.isEmpty)
        XCTAssertEqual(group.defaultSet.name, "Default")
        XCTAssertNil(store.load(forOwner: "owner"), "nothing was written")
        XCTAssertTrue(perform(.show(name: "Default")).isSuccess)
    }

    func testAnOpenThatLandsNothingLeavesNothingBehind() throws {
        let folder = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        let missing = dir.appendingPathComponent("missing.swift").path

        let reply = perform(
            .open(
                name: "auth", paths: [missing, folder.path, "relative.swift"]
            )
        )

        XCTAssertFalse(reply.isSuccess)
        XCTAssertEqual(
            reply.message,
            [
                "Nothing was opened.",
                "Not opened: \(missing) — no such file.",
                "Not opened: \(folder.path) — a folder, not a file.",
                "Not opened: relative.swift — not an absolute path.",
            ].joined(separator: "\n")
        )
        XCTAssertNil(group.set(named: "auth"))
        XCTAssertNil(store.load(forOwner: "owner"))
        XCTAssertEqual(host.shown, 0)
    }

    func testASetMadeForFilesThatWouldNotOpenIsTakenAwayAgain() throws {
        let binary = dir.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: binary)

        let reply = perform(.open(name: "auth", paths: [binary.path]))

        XCTAssertFalse(reply.isSuccess)
        XCTAssertEqual(
            reply.message,
            "Nothing was opened.\nNot opened: \(binary.path) — not a text "
                + "file or an image."
        )
        XCTAssertEqual(group.sets.count, 1)
        XCTAssertEqual(host.shown, 0)
    }

    func testFilesThatCannotBeOpenedAreNamedAndTheRestOpen() throws {
        let good = try write("good.swift")
        let missing = dir.appendingPathComponent("gone.swift").path

        let object = try json(
            perform(.open(name: "auth", paths: [good.path, missing]))
        )

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["opened"] as? [String], [good.path])
        XCTAssertEqual(
            object["not_opened"] as? [[String: String]],
            [["path": missing, "reason": "no such file"]]
        )
        XCTAssertEqual(
            object["message"] as? String,
            "Made “auth” and opened 1 file in it. It is on screen.\n"
                + "Not opened: \(missing) — no such file."
        )
    }

    func testWhyAFileWouldNotOpenIsSaidPlainly() {
        XCTAssertEqual(
            FilesSurface.reason(for: ReaderFile.LoadFailure.notText),
            "not a text file or an image"
        )
        XCTAssertEqual(
            FilesSurface.reason(
                for: ReaderFile.LoadFailure.tooLarge(
                    byteSize: 12_345_678, cap: 5_000_000
                )
            ),
            "too large to open here (12.3 MB; the limit is 5.0 MB)"
        )
        XCTAssertEqual(
            FilesSurface.reason(for: ReaderFile.LoadFailure.unreadable),
            "could not be read"
        )
    }

    func testANewSetBrowsesFromTheDefaultRootWhenItHoldsEveryFile() {
        let root = URL(fileURLWithPath: "/Users/k/projects/app")

        XCTAssertEqual(
            FilesSurface.agentSetRoot(
                for: [
                    URL(fileURLWithPath: "/Users/k/projects/app/src/a.rb"),
                    URL(fileURLWithPath: "/Users/k/projects/app/b.rb"),
                ],
                defaultRoot: root
            ).path,
            root.path
        )
    }

    func testOtherwiseItBrowsesFromTheDeepestFolderHoldingThemAll() {
        let root = URL(fileURLWithPath: "/Users/k/projects/app")

        XCTAssertEqual(
            FilesSurface.agentSetRoot(
                for: [
                    URL(fileURLWithPath: "/Users/k/notes/a.md"),
                    URL(fileURLWithPath: "/Users/k/notes/2026/b.md"),
                ],
                defaultRoot: root
            ).path,
            "/Users/k/notes"
        )
        XCTAssertEqual(
            FilesSurface.agentSetRoot(
                for: [URL(fileURLWithPath: "/etc/hosts")], defaultRoot: root
            ).path,
            "/etc"
        )
        XCTAssertEqual(
            FilesSurface.agentSetRoot(
                for: [URL(fileURLWithPath: "/Users/kelly/a.md")],
                defaultRoot: URL(fileURLWithPath: "/Users/k")
            ).path,
            "/Users/kelly",
            "a shared run of letters is not a shared folder"
        )
    }

    func testSavedSetsAreReadBeforeTheAgentChangesAnything() throws {
        let mine = try write("mine.swift")
        let theirs = try write("theirs.swift")
        store.saved["owner"] = PersistedFileSetGroup(
            sets: [
                PersistedFileSet(
                    id: FileSetGroup.defaultSetID(forOwner: "owner"),
                    name: "Default",
                    root: dir.path,
                    openPathRows: [[mine.path]],
                    selectedPath: mine.path
                )
            ],
            selectedID: nil
        )

        perform(.open(name: "auth", paths: [theirs.path]))

        XCTAssertEqual(group.defaultSet.openPathRows, [[mine.path]])
        XCTAssertEqual(
            store.load(forOwner: "owner")?.sets.map(\.openPathRows),
            [[[mine.path]], [[theirs.path]]]
        )
    }

    // MARK: - Showing

    func testShowingPutsASetOnScreen() throws {
        let a = try write("a.swift")
        perform(.open(name: "auth", paths: [a.path]))

        let reply = perform(.show(name: "default"))

        XCTAssertEqual(reply.message, "“Default” is on screen.")
        XCTAssertTrue(group.selected.isDefault)
        XCTAssertEqual(host.shown, 2)
        XCTAssertEqual(
            store.load(forOwner: "owner")?.selectedID, group.defaultSet.id
        )
    }

    func testAnOwnerNotOnScreenHasItsSetChosenButNotShown() throws {
        let a = try write("a.swift")
        host.currentOwnerID = "someone-else"

        let reply = perform(.open(name: "auth", paths: [a.path]))

        XCTAssertEqual(
            reply.message,
            "Made “auth” and opened 1 file in it. It will be on screen when "
                + "the user next comes back to it."
        )
        XCTAssertEqual(group.selected.name, "auth")
        XCTAssertEqual(host.shown, 0)
    }

    func testSwitchingSetsForTheOwnerInFrontTakesThePanelsDown() throws {
        let a = try write("a.swift")
        FilePickerPresenter.shared.present()
        XCTAssertTrue(FilePickerPresenter.shared.isPresented)

        perform(.open(name: "auth", paths: [a.path]))

        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    func testAPanelLeftOpenOnLeavingDoesNotComeBackOverTheAgentsFiles() throws {
        let a = try write("a.swift")
        FilePickerPresenter.shared.present()
        surface.leaveFilesSurface()

        perform(.open(name: "auth", paths: [a.path]))
        surface.enterFilesSurface(agentRoot: nil)

        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    // MARK: - Renaming and removing

    func testRenamingReportsAClashAndRenames() throws {
        let a = try write("a.swift")
        perform(.open(name: "auth", paths: [a.path]))
        perform(.open(name: "billing", paths: [a.path]))

        XCTAssertEqual(
            perform(.rename(name: "billing", to: "AUTH")).message,
            "“auth” is already a set here."
        )
        XCTAssertEqual(
            perform(.rename(name: "billing", to: "payments")).message,
            "Renamed “billing” to “payments”."
        )
        XCTAssertEqual(
            store.load(forOwner: "owner")?.sets.map(\.name),
            ["Default", "auth", "payments"]
        )
    }

    func testRemovingASetTheAgentMadeClosesItAndShowsTheDefault() throws {
        let a = try write("a.swift")
        let b = try write("b.swift")
        perform(.open(name: "auth", paths: [a.path, b.path]))

        let object = try json(perform(.remove(name: "auth")))

        XCTAssertEqual(
            object["message"] as? String,
            "Removed “auth” and closed the 2 files open in it."
        )
        XCTAssertEqual(object["removed"] as? String, "auth")
        XCTAssertEqual(object["closed_files"] as? Int, 2)
        XCTAssertNil(group.set(named: "auth"))
        XCTAssertTrue(group.selected.isDefault)
        XCTAssertEqual(store.load(forOwner: "owner")?.sets.count, 1)
    }

    func testASetTheUserMadeIsNotTheAgentsToRemove() {
        surface.createSet(named: "mine")
        FilePickerPresenter.shared.dismiss()

        let reply = perform(.remove(name: "mine"))

        XCTAssertEqual(
            reply.message,
            "“mine” was made by the user, and you can only remove sets you made."
        )
        XCTAssertNotNil(group.set(named: "mine"))
    }

    func testASetHoldingNotesStaysUntilTheyAreSentOrDiscarded() throws {
        let a = try write("a.swift")
        perform(.open(name: "auth", paths: [a.path]))
        let auth = try XCTUnwrap(group.set(named: "auth"))
        auth.addNote(
            filePath: a.path, startLine: 1, endLine: 1,
            lineContent: "one", content: "why", createdAt: "now"
        )

        let reply = perform(.remove(name: "auth"))

        XCTAssertEqual(
            reply.message,
            "“auth” holds 1 unsent note, so it stays until the user sends or "
                + "discards it."
        )
        XCTAssertNotNil(group.set(named: "auth"))
    }

    func testWhatARemovalSaysAboutTheFilesItClosed() {
        XCTAssertEqual(
            FilesSurface.removedMessage(setName: "auth", closedFiles: 0),
            "Removed “auth”; it had no files open."
        )
        XCTAssertEqual(
            FilesSurface.removedMessage(setName: "auth", closedFiles: 1),
            "Removed “auth” and closed the file open in it."
        )
    }

    // MARK: - The reply

    func testARepliesKeysAreSortedAndItsPathsReadAsWritten() throws {
        let a = try write("a.swift")

        let text = try XCTUnwrap(
            String(
                data: perform(.open(name: "auth", paths: [a.path])).jsonData(),
                encoding: .utf8
            )
        )

        XCTAssertTrue(text.contains(a.path), "slashes are left unescaped")
        XCTAssertTrue(
            text.hasPrefix(#"{"already_open":[],"created":true,"message":"#),
            text
        )
    }
}
