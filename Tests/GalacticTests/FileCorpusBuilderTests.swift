import XCTest

@testable import Galactic

/// What the walk finds, and the two things it must never do.
///
/// The comparison against `FileManager` is the load-bearing test here.
/// `getattrlistbulk` hands back a packed buffer whose fields are read by byte
/// offset, and the failure mode of getting an offset wrong is not a crash —
/// it is plausible-looking rubbish. Only agreement with an independent
/// enumeration catches that.
final class FileCorpusBuilderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func touch(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    private func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    private func build(skipping: Set<String> = []) -> FileCorpus {
        FileCorpusBuilder.build(root: root, skipping: skipping)
    }

    private func paths(_ corpus: FileCorpus) -> Set<String> {
        Set((0..<corpus.entryCount).map { corpus.relativePath(at: $0) })
    }

    // MARK: - Agreement with an independent walk

    /// The decoder check. If a byte offset in the packed entry is wrong, names
    /// come back truncated or shifted and this is what says so.
    func testFindsExactlyWhatFileManagerFinds() throws {
        for path in [
            "a.txt", "nested/b.txt", "nested/deeper/c.txt", ".hidden",
            "nested/.hidden-too", "name with spaces.txt", "café.md",
        ] {
            try touch(path)
        }

        let corpus = build()
        var expected: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )!
        for case let url as URL in enumerator {
            if let relative = FilePaths.relativePath(of: url, under: root) {
                expected.insert(relative)
            }
        }

        XCTAssertEqual(paths(corpus), expected)
    }

    /// A modification time read from the wrong offset is still a plausible
    /// date, so this pins it against the file system's own answer.
    func testModificationTimeMatchesTheFileSystem() throws {
        let url = try touch("dated.txt")
        let actual = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.modificationDate] as! Date

        let corpus = build()
        let index = (0..<corpus.entryCount).first {
            corpus.relativePath(at: $0) == "dated.txt"
        }
        XCTAssertNotNil(index)
        XCTAssertEqual(
            corpus.modified(at: index!).timeIntervalSince1970,
            actual.timeIntervalSince1970,
            accuracy: 86_400
        )
    }

    // MARK: - Symlinks

    /// The regression this walk exists to fix.
    ///
    /// `~/projects/implementation-plans` is a symlink into a sync target, so
    /// under the previous walk every implementation plan on this machine was
    /// unfindable and nothing said so.
    func testDescendsIntoSymlinkedDirectory() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("x".utf8).write(to: outside.appendingPathComponent("inside.md"))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside
        )

        XCTAssertTrue(paths(build()).contains("linked/inside.md"))
    }

    /// And the hazard the old refusal was avoiding. A link pointing at an
    /// ancestor must stop, and stop by identity rather than by running out of
    /// depth.
    func testSymlinkToAncestorTerminates() throws {
        try touch("real.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )

        let corpus = build()
        XCTAssertTrue(paths(corpus).contains("real.txt"))
        // The link itself is recorded; what must not happen is descending
        // through it and finding `loop/loop/loop/real.txt`.
        XCTAssertFalse(
            paths(corpus).contains { $0.hasPrefix("loop/loop") },
            "the walk followed a cycle"
        )
    }

    func testSymlinkToFileIsIndexedAsAFile() throws {
        let target = try touch("target.txt")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.txt"), withDestinationURL: target
        )

        let corpus = build()
        let index = (0..<corpus.entryCount).first {
            corpus.relativePath(at: $0) == "alias.txt"
        }
        XCTAssertNotNil(index)
        XCTAssertFalse(corpus.isDirectory(at: index!))
    }

    // MARK: - Policy

    /// The skip list names directories not to descend into, not names to
    /// blacklist — a *file* called `build` is still a file. An earlier
    /// reordering of this check broke exactly that.
    func testSkipListSkipsDirectoriesButNotFilesOfTheSameName() throws {
        try touch("build/artifact.o")
        try touch("src/build")  // a *file* of the skipped name
        try touch("src/main.swift")

        let corpus = build(skipping: ["build"])
        let found = paths(corpus)
        XCTAssertTrue(found.contains("src/main.swift"))
        XCTAssertTrue(
            found.contains("src/build"), "a file of the skipped name was dropped"
        )
        XCTAssertFalse(found.contains("build/artifact.o"))
    }

    func testIndexesHiddenFiles() throws {
        try touch(".gitignore")
        try touch(".config/settings.json")
        let found = paths(build())
        XCTAssertTrue(found.contains(".gitignore"))
        XCTAssertTrue(found.contains(".config/settings.json"))
    }

    func testIndexesDirectoriesAlongsideFiles() throws {
        try touch("src/main.swift")
        _ = try directory("empty")

        let corpus = build()
        let directories = (0..<corpus.entryCount)
            .filter { corpus.isDirectory(at: $0) }
            .map { corpus.relativePath(at: $0) }
        XCTAssertEqual(Set(directories), ["src", "empty"])
    }

    func testEntriesComeBackSorted() throws {
        for path in ["z.txt", "a.txt", "m/n.txt", "m/a.txt"] { try touch(path) }
        let corpus = build()
        let listed = (0..<corpus.entryCount).map { corpus.relativePath(at: $0) }
        XCTAssertEqual(listed, listed.sorted())
    }

    func testCancellationStopsTheWalk() throws {
        for index in 0..<50 { try touch("dir\(index)/file.txt") }
        let corpus = FileCorpusBuilder.build(
            root: root, skipping: [], isCancelled: { true }
        )
        XCTAssertTrue(corpus.isEmpty)
    }
}
