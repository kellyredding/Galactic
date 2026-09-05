import AppKit
import XCTest

@testable import Galactic

/// What reveal refuses.
///
/// The mechanism is covered by `FilePickerRevealTests`; what is only visible
/// here is what the surface declines to hand it, because only the surface knows
/// which of its own tabs is not really a file.
@MainActor
final class FilesSurfaceRevealTests: XCTestCase {

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

    private var dir: URL!
    private var host: Host!
    private var surface: FilesSurface!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        // The shared picker is process-wide, so a test that asserts it stayed
        // shut has to start from shut.
        FilePickerPresenter.shared.dismiss()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        host = Host()
        host.root = dir
        surface = FilesSurface(host: host)
    }

    override func tearDownWithError() throws {
        FilePickerPresenter.shared.dismiss()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ relative: String, into base: URL? = nil) throws -> URL {
        let url = (base ?? dir).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: - Refusals

    /// Nothing selected is nothing to reveal, and the picker is not opened on
    /// the way to finding that out.
    func testAnEmptyStripRevealsNothing() {
        surface.revealSelectedFile()

        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    /// **The results tab is a file on disk and not a file the reader has.**
    /// Revealing it climbs out of their tree to show them something synthetic.
    func testTheSearchResultsTabIsRefused() throws {
        let results = FilesSurface.searchResultsURL(owner: host.currentOwnerID)
        try FileManager.default.createDirectory(
            at: results.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("results".utf8).write(to: results)
        defer { try? FileManager.default.removeItem(at: results) }
        try surface.currentSet.open(url: results)

        surface.revealSelectedFile()

        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    /// A file deleted under the reader has no folder to be shown in, and the
    /// root it would be resolved against is a path that is not there.
    func testAFileDeletedSinceItWasOpenedIsRefused() throws {
        let file = try write("app/user.swift")
        try surface.currentSet.open(url: file)
        try FileManager.default.removeItem(at: file)

        surface.revealSelectedFile()

        XCTAssertFalse(FilePickerPresenter.shared.isPresented)
    }

    // MARK: - Revealing

    func testAnOpenFileOpensThePickerAimedAtIt() throws {
        let file = try write("app/user.swift")
        try surface.currentSet.open(url: file)

        surface.revealSelectedFile()

        XCTAssertTrue(FilePickerPresenter.shared.isPresented)
        XCTAssertEqual(FilePickerPresenter.shared.mode, .browse)
    }
}
