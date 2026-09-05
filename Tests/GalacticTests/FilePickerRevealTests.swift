import AppKit
import XCTest

@testable import Galactic

/// Revealing a file in the Browse tree.
///
/// Every test here has to `settle`, and that is the feature rather than the
/// test's inconvenience: a chain of folders opens one directory read at a time,
/// so what is being asserted is that the selection is still claimed several
/// passes after the call that asked for it.
@MainActor
final class FilePickerRevealTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `captureFocus` reads `NSApp`, which is nil until something asks for
        // the shared application.
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private func opened(root: URL) -> FilePickerPresenter {
        let p = FilePickerPresenter()
        p.rootProvider = { root }
        p.ownerProvider = { "owner" }
        p.present()
        return p
    }

    /// Spin the main loop until a condition holds. Expanding reads a directory
    /// off the main actor, so a tree arrives over several passes rather than in
    /// the call that asked for it.
    private func settle(
        _ description: String, until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    // MARK: - Landing on the file

    func testRevealingExpandsDownToTheFileAndSelectsIt() throws {
        let file = try write("app/models/user.swift")
        let root = FilePaths.canonical(dir)
        let p = opened(root: dir)

        p.reveal(file: file, rootedAt: dir)

        settle("the chain to open") {
            p.treeRows.contains { $0.path == root + "/app/models/user.swift" }
        }
        XCTAssertEqual(p.mode, .browse)
        XCTAssertEqual(
            p.treeRows[p.treeSelectedIndex].path,
            root + "/app/models/user.swift"
        )
    }

    /// Asked for, because it is what makes the row visible rather than merely
    /// selected.
    func testRevealingAsksToScrollToTheFile() throws {
        let file = try write("app/models/user.swift")
        let root = FilePaths.canonical(dir)
        let p = opened(root: dir)

        p.reveal(file: file, rootedAt: dir)

        settle("the scroll to be claimed") { p.scrollTarget != nil }
        XCTAssertEqual(
            p.scrollTarget,
            .init(mode: .browse, id: root + "/app/models/user.swift")
        )
    }

    /// **The query is what makes the tree reachable.** Left set, `refreshTree`
    /// builds from the index and the expansion set is never read.
    func testRevealingClearsTheFilter() throws {
        let file = try write("app/models/user.swift")
        let p = opened(root: dir)
        p.selectMode(.browse)
        p.query = "zzz"

        p.reveal(file: file, rootedAt: dir)

        XCTAssertEqual(p.query, "")
    }

    /// A reveal that does not move the root adds expansions and takes none
    /// away, so folders opened earlier are still open.
    func testRevealingInTheSameRootKeepsOtherFoldersOpen() throws {
        try write("other/keep.swift")
        let file = try write("app/models/user.swift")
        let root = FilePaths.canonical(dir)
        let p = opened(root: dir)
        p.selectMode(.browse)
        settle("the root to be read") { p.treeRows.count > 1 }
        let other = try XCTUnwrap(
            p.treeRows.first { $0.path == root + "/other" }
        )
        p.selectTreeRow(other)
        p.expandSelectedTreeRow()
        settle("other to be read") {
            p.treeRows.contains { $0.path == root + "/other/keep.swift" }
        }

        p.reveal(file: file, rootedAt: dir)

        settle("the chain to open") {
            p.treeRows.contains { $0.path == root + "/app/models/user.swift" }
        }
        XCTAssertTrue(
            p.treeRows.contains { $0.path == root + "/other/keep.swift" },
            "a reveal that does not climb only adds"
        )
    }

    // MARK: - Moving the root

    /// Revealing a file outside the root moves the root and reports it, so the
    /// host can persist where the reader now is.
    func testRevealingOutsideTheRootRerootsAndTellsTheHost() throws {
        let file = try write("outer/app/user.swift")
        let inner = dir.appendingPathComponent("outer/app")
        let p = opened(root: inner)
        var reported: URL?
        p.onChangeRoot = { reported = $0 }

        p.reveal(file: file, rootedAt: dir)

        XCTAssertEqual(reported?.path, dir.path)
        settle("the chain to open") {
            p.treeRows.contains {
                $0.path == FilePaths.canonical(dir) + "/outer/app/user.swift"
            }
        }
    }

    /// The field above the query names the root, and nothing else tells it the
    /// root moved — so without a nudge it goes on naming where the reader was
    /// until the caret lands in it.
    func testRevealingOutsideTheRootRenamesTheRootField() throws {
        let file = try write("outer/app/user.swift")
        let inner = dir.appendingPathComponent("outer/app")
        let p = opened(root: inner)

        p.reveal(file: file, rootedAt: dir)

        XCTAssertEqual(p.rootFieldModel.field.text, dir.path)
    }

    /// **Revealing leaves no trace of a filter that was up.** The query goes,
    /// and so does every match highlight it put on the tree — a highlighted row
    /// under an empty field is the visible half of a scan that outlived its
    /// question.
    func testRevealingWhileFilteringLeavesNoHighlighting() throws {
        let file = try write("app/models/user.swift")
        try write("unrelated.md")
        let root = FilePaths.canonical(dir)
        let p = opened(root: dir)
        p.selectMode(.browse)
        p.query = "user"
        settle("the filter to land") {
            p.treeRows.contains { !$0.matchedOffsets.isEmpty }
        }

        p.reveal(file: file, rootedAt: dir)
        settle("the chain to open") {
            p.treeRows.contains { $0.path == root + "/app/models/user.swift" }
        }

        XCTAssertEqual(p.query, "")
        XCTAssertTrue(
            p.treeRows.allSatisfy { $0.matchedOffsets.isEmpty },
            "no row still carries the filter's highlighting"
        )
        XCTAssertTrue(
            p.treeRows.allSatisfy { !$0.isRevealedByFilter },
            "no row is on screen only because the filter put it there"
        )
    }

    // MARK: - Spelling

    /// **A file under a symlinked folder still lands.**
    ///
    /// The tree spells children against the parent it asked for rather than
    /// resolving them, so a canonicalised target would name a row that does not
    /// exist — and the failure is silent: the chain opens onto nothing and the
    /// selection is never claimed.
    func testAFileReachedThroughASymlinkedFolderIsStillFound() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("models"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(
            to: real.appendingPathComponent("models/user.swift")
        )
        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: real
        )
        let root = FilePaths.canonical(dir)
        let p = opened(root: dir)

        p.reveal(
            file: link.appendingPathComponent("models/user.swift"),
            rootedAt: dir
        )

        settle("the chain through the link to open") {
            p.treeRows.contains {
                $0.path == root + "/linked/models/user.swift"
            }
        }
        XCTAssertEqual(
            p.treeRows[p.treeSelectedIndex].path,
            root + "/linked/models/user.swift"
        )
    }
}
