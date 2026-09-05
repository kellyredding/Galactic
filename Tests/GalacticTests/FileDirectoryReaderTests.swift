import XCTest

@testable import Galactic

/// Reading a directory for the panels.
///
/// One case, and it is the one that fails silently: a symlinked directory
/// answers as a directory, opens like a directory, and lists nothing — which a
/// reader cannot tell apart from an empty folder.
final class FileDirectoryReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dir-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// **`contentsOfDirectory(at:)` refuses a link to a directory** while the
    /// by-path form answers it, so the reader has to try both. Without the
    /// second attempt every symlinked folder in the tree is an empty one.
    func testASymlinkedDirectoryListsItsContents() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: real.appendingPathComponent("a.swift"))
        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: real
        )

        let entries = FileDirectoryReader.childEntries(of: link.path)

        XCTAssertEqual(entries.map(\.path), [link.path + "/a.swift"])
    }

    /// The link itself is browsable, which is what puts it on screen with an
    /// arrow to open in the first place.
    func testALinkToADirectoryReadsAsADirectory() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: true
        )
        let link = dir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: real
        )

        let entries = FileDirectoryReader.childEntries(of: dir.path)

        XCTAssertEqual(
            entries.filter(\.isDirectory).map(\.path).sorted(),
            [dir.path + "/linked", dir.path + "/real"]
        )
    }
}
