import XCTest

@testable import Galactic

/// What the index finds, and what it deliberately never looks at.
///
/// The skip list is the whole filtering policy — there is no gitignore behind
/// it — so these are the assertions that keep a repository's noise out of a
/// picker without also keeping a reader's own code out.
final class FileTreeIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Create a file at a relative path, making directories as needed.
    private func touch(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    private func index(
        skipping: Set<String> = FileTreeIndex.defaultSkipList,
        depthCap: Int = 12,
        resultCap: Int = 50_000
    ) -> FileTreeIndex {
        FileTreeIndex.build(
            root: root, skipping: skipping,
            depthCap: depthCap, resultCap: resultCap
        )
    }

    private func relatives(_ i: FileTreeIndex) -> Set<String> {
        Set(i.items.map(\.relativePath))
    }

    // MARK: - What it finds

    func testItFindsFilesAtEveryDepth() throws {
        try touch("top.swift")
        try touch("src/mid.swift")
        try touch("src/deep/deeper/leaf.swift")

        XCTAssertEqual(
            relatives(index()),
            ["top.swift", "src/mid.swift", "src/deep/deeper/leaf.swift"]
        )
    }

    func testDirectoriesAreNotThemselvesItems() throws {
        try touch("src/a.swift")

        XCTAssertEqual(index().items.count, 1)
    }

    /// Dotfiles are among the things most worth opening, and the kind table was
    /// widened during pre-work specifically so they resolve. A blanket
    /// hidden-file flag would have thrown them away.
    func testDotfilesAreIndexed() throws {
        try touch(".gitignore")
        try touch(".env")
        try touch("Makefile")

        XCTAssertEqual(
            relatives(index()), [".gitignore", ".env", "Makefile"]
        )
    }

    func testPathsArePreLowercasedForMatching() throws {
        try touch("Src/UserModel.swift")

        let item = index().items.first
        XCTAssertEqual(item?.relativePath, "Src/UserModel.swift")
        XCTAssertEqual(
            item?.lowercasedRelativePath, "src/usermodel.swift",
            "lowercased once here, for the filter in front of the matcher"
        )
    }

    // MARK: - What it skips

    func testASkippedDirectoryContributesNothing() throws {
        try touch("app.js")
        try touch("node_modules/left-pad/index.js")
        try touch("node_modules/react/index.js")

        XCTAssertEqual(relatives(index()), ["app.js"])
    }

    /// A skipped name is skipped wherever it appears, not only at the top.
    func testASkippedNameNestedDeepIsStillSkipped() throws {
        try touch("packages/web/node_modules/dep/index.js")
        try touch("packages/web/app.js")

        XCTAssertEqual(relatives(index()), ["packages/web/app.js"])
    }

    func testTheVersionControlDirectoryIsSkipped() throws {
        try touch(".git/objects/ab/cdef")
        try touch("README.md")

        XCTAssertEqual(relatives(index()), ["README.md"])
    }

    /// The names deliberately left out of the list. `lib` is dependencies in
    /// Crystal and source in Ruby; `vendor` is checked-in source often enough to
    /// matter. Hiding a reader's own code is the worse failure.
    func testAmbiguousDirectoryNamesAreNotSkipped() throws {
        try touch("lib/thing.rb")
        try touch("src/thing.rb")
        try touch("bin/tool")
        try touch("vendor/gem/thing.rb")

        XCTAssertEqual(
            relatives(index()),
            ["lib/thing.rb", "src/thing.rb", "bin/tool", "vendor/gem/thing.rb"]
        )
    }

    func testAnEmptySkipListIndexesEverything() throws {
        try touch("app.js")
        try touch("node_modules/dep/index.js")

        XCTAssertEqual(
            relatives(index(skipping: [])),
            ["app.js", "node_modules/dep/index.js"]
        )
    }

    /// A file whose *name* matches a skip entry is still a file. The list names
        /// directories not to descend into, not names to blacklist.
    func testAFileNamedLikeASkippedDirectoryIsStillIndexed() throws {
        try touch("build")

        XCTAssertEqual(relatives(index()), ["build"])
    }

    // MARK: - Ceilings

    func testTheDepthCapStopsDescending() throws {
        try touch("a/b/c/d/deep.swift")
        try touch("shallow.swift")

        let shallowOnly = index(depthCap: 2)

        XCTAssertTrue(relatives(shallowOnly).contains("shallow.swift"))
        XCTAssertFalse(relatives(shallowOnly).contains("a/b/c/d/deep.swift"))
    }

    /// Reported rather than swallowed: a picker that silently searched half a
    /// repository would rank confidently over the wrong corpus.
    func testHittingTheResultCapIsReported() throws {
        for i in 0..<10 { try touch("f\(i).swift") }

        let capped = index(resultCap: 4)

        XCTAssertEqual(capped.items.count, 4)
        XCTAssertTrue(capped.wasTruncated)
    }

    func testFinishingTheWalkIsNotReportedAsTruncated() throws {
        try touch("a.swift")

        XCTAssertFalse(index().wasTruncated)
    }

    // MARK: - Degenerate roots

    func testARootThatDoesNotExistIndexesNothing() {
        let missing = root.appendingPathComponent("not-here")
        let i = FileTreeIndex.build(root: missing)

        XCTAssertTrue(i.items.isEmpty)
        XCTAssertFalse(i.wasTruncated)
    }

    func testAnEmptyRootIndexesNothing() {
        XCTAssertTrue(index().items.isEmpty)
    }

    /// The resolved root, not the one passed in. On this platform the paths
    /// people browse are full of symlinks, and comparing an unresolved root
    /// against a resolved child is what made every relative path come back
    /// absolute.
    func testTheRootIsCarriedResolved() throws {
        try touch("a.swift")

        XCTAssertEqual(
            index().root.path, FilePaths.canonical(root),
            "canonical through realpath — the Foundation spellings disagree "
                + "with each other and with the enumerator"
        )
    }

    func testASymlinkedRootStillProducesRelativePaths() throws {
        try touch("src/a.swift")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root
        )
        defer { try? FileManager.default.removeItem(at: link) }

        let viaLink = FileTreeIndex.build(root: link)

        XCTAssertEqual(
            Set(viaLink.items.map(\.relativePath)), ["src/a.swift"]
        )
    }
}
