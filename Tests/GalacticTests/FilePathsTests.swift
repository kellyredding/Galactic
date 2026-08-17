import XCTest

@testable import Galactic

/// Deciding whether one path is inside another.
///
/// Its own type because getting it wrong is silent — three callers need the same
/// answer, and when they disagreed the result was a picker full of absolute
/// paths with nothing failing.
final class FilePathsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Inside and outside

    func testAChildIsRelativeToItsRoot() throws {
        let child = dir.appendingPathComponent("src/a.swift")
        try FileManager.default.createDirectory(
            at: child.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: child)

        XCTAssertEqual(
            FilePaths.relativePath(of: child, under: dir), "src/a.swift"
        )
    }

    func testAPathOutsideTheRootIsNil() {
        XCTAssertNil(
            FilePaths.relativePath(
                of: URL(fileURLWithPath: "/elsewhere/a.swift"),
                under: URL(fileURLWithPath: "/work/project")
            )
        )
    }

    /// Component-wise, not by string prefix: a sibling whose name merely begins
    /// with the root's is outside it.
    func testASiblingSharingAPrefixIsOutside() {
        XCTAssertNil(
            FilePaths.relativePath(
                of: URL(fileURLWithPath: "/work/project-other/a.swift"),
                under: URL(fileURLWithPath: "/work/project")
            )
        )
    }

    func testTheRootItselfIsNotRelativeToItself() {
        XCTAssertNil(FilePaths.relativePath(of: dir, under: dir))
    }

    // MARK: - The two failures that made this a type

    /// A root reached through a symlink. `/var` is one, and the directory
    /// enumerator returns `/private/var` whichever form it was handed.
    func testASymlinkedRootStillResolves() throws {
        let child = dir.appendingPathComponent("a.swift")
        try Data("x".utf8).write(to: child)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-paths-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir
        )
        defer { try? FileManager.default.removeItem(at: link) }

        XCTAssertEqual(
            FilePaths.relativePath(of: child, under: link), "a.swift"
        )
    }

    /// The picker's empty list is made of files a reader *closed*, and some will
    /// have been deleted since — so a path that cannot be resolved at all still
    /// has to come back relative rather than absolute.
    func testAPathThatNoLongerExistsIsStillRelative() {
        let gone = dir.appendingPathComponent("deleted/since.swift")

        XCTAssertEqual(
            FilePaths.relativePath(of: gone, under: dir),
            "deleted/since.swift"
        )
    }

    func testAMissingPathOutsideTheRootIsStillNil() {
        XCTAssertNil(
            FilePaths.relativePath(
                of: URL(fileURLWithPath: "/nowhere/gone.swift"), under: dir
            )
        )
    }

    // MARK: - Canonical

    func testCanonicalResolvesAnExistingPath() throws {
        let child = dir.appendingPathComponent("a.swift")
        try Data("x".utf8).write(to: child)

        XCTAssertEqual(
            FilePaths.canonical(child),
            FilePaths.canonical(dir) + "/a.swift"
        )
    }

    /// Returned as it was, which is the right answer for something deleted.
    func testCanonicalPassesThroughAPathItCannotResolve() {
        let gone = URL(fileURLWithPath: "/definitely/not/here.swift")

        XCTAssertEqual(FilePaths.canonical(gone), "/definitely/not/here.swift")
    }
}
