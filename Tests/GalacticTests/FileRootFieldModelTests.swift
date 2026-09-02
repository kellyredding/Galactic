import XCTest

@testable import Galactic

/// The root field, working: the directory reads, the cache bound, and what is
/// offered.
///
/// `FileRootFieldTests` covers the rules as values. What only this file can
/// cover is the part that touches a disk — and most of these assertions moved
/// here from the picker's own suite, where they were reached through a query
/// field that no longer does this job. They are asserted once here because both
/// panels hold one of these, so neither can drift from the other.
@MainActor
final class FileRootFieldModelTests: XCTestCase {

    /// The route the model is pointed at.
    private var dir: URL!

    /// The route's parent, and the reason it exists rather than being whatever
    /// the machine's temporary directory happens to be.
    ///
    /// The field opens on a path with **no trailing slash**, so the first
    /// directory it reads is the route's parent, not the route. Left at the
    /// temporary directory that is the parent of every other test's scratch
    /// space too, so what this suite read depended on how many of those the
    /// machine had accumulated — 346 of them, a week after these tests last
    /// passed, which is when the read became slow enough to land second and
    /// take the cache with it. Owning the parent makes both reads this suite's
    /// own, so a test fails for a reason in the code.
    private var outer: URL!

    override func setUpWithError() throws {
        outer = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-model-\(UUID().uuidString)")
        dir = outer.appendingPathComponent("route")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outer)
    }

    private func makeDir(_ name: String) throws -> URL {
        try makeDir(name, in: dir)
    }

    private func makeDir(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    private func model(
        onCommit: @escaping (URL) -> Void = { _ in }
    ) -> FileRootFieldModel {
        let m = FileRootFieldModel(route: { [dir] in dir }, onCommit: onCommit)
        m.beginEditing()
        return m
    }

    /// Long enough for one directory read to land.
    private func settle(_ m: FileRootFieldModel) async throws {
        for _ in 0..<200 {
            if !m.rows.isEmpty { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - What is offered

    func testAPartialSegmentOffersTheMatchingFolders() async throws {
        for name in ["alpha", "beta"] { _ = try makeDir(name) }
        try Data("x".utf8).write(
            to: dir.appendingPathComponent("notafolder.rb")
        )
        let m = model()

        m.edit(dir.path + "/a")
        try await settle(m)

        XCTAssertEqual(m.rows.map(\.relativePath), ["alpha"])
        XCTAssertEqual(m.rows.first?.source, .folder)
    }

    /// A file is not somewhere anyone can browse to, so it is never offered.
    func testAFileIsNeverOffered() async throws {
        _ = try makeDir("adir")
        try Data("x".utf8).write(to: dir.appendingPathComponent("afile.rb"))
        let m = model()

        m.edit(dir.path + "/")
        try await settle(m)

        XCTAssertEqual(m.rows.map(\.relativePath), ["adir"])
    }

    /// **The symlink rules, and they were measured rather than assumed.** The
    /// directory key has `lstat` semantics, so it is false for every symlink
    /// including one pointing straight at a directory — enumerating `/` with
    /// that predicate alone yields no `tmp`, `var` or `etc` at all. A symlinked
    /// folder has to be offered and a symlinked file must not be.
    func testASymlinkedDirectoryIsOfferedAndASymlinkedFileIsNot() async throws {
        let realDir = try makeDir("realdir")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linkdir"),
            withDestinationURL: realDir
        )
        let realFile = dir.appendingPathComponent("real.rb")
        try Data("x".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linkfile.rb"),
            withDestinationURL: realFile
        )
        let m = model()

        m.edit(dir.path + "/")
        try await settle(m)

        XCTAssertEqual(m.rows.map(\.relativePath), ["linkdir", "realdir"])
    }

    /// Typing inside one directory reads it once, not once per keystroke — the
    /// bound that keeps a directory read and a per-entry attribute lookup off
    /// the path every keystroke travels. Measured at 213 ms of a 218 ms burst
    /// when it was on the main actor.
    func testTypingFurtherInsideOneDirectoryReadsItOnce() async throws {
        for name in ["alpha", "album"] { _ = try makeDir(name) }
        let m = model()

        m.edit(dir.path + "/al")
        try await settle(m)
        XCTAssertEqual(m.rows.count, 2, "precondition: both matched")

        // Narrowing within the same parent must answer from the held children
        // rather than the disk, so it lands without waiting.
        m.edit(dir.path + "/alp")

        XCTAssertEqual(
            m.rows.map(\.relativePath), ["alpha"],
            "narrowing answered synchronously, so nothing was read again"
        )
    }

    /// A read landing for a parent the field has left must not evict the parent
    /// it is in.
    ///
    /// Two reads are in flight together as a matter of course, because the
    /// field opens on a path with no trailing slash and so reads the route's
    /// parent first, then the route itself as soon as a separator is typed. One
    /// slot holds one parent, so whichever lands last wins — and when the one
    /// the field has *left* is the larger, it wins by being slower.
    ///
    /// The ordering here is arranged rather than hoped for: the parent is given
    /// enough entries that its read is comfortably the slower of the two, so it
    /// is certain to land second. Before the fix the cache then named the
    /// parent, and every keystroke inside the route went back to the disk for
    /// children already in hand — which is the only way this is visible from
    /// outside, and why the cache is reachable from here at all.
    func testALateReadForALeftParentDoesNotEvictTheHeldOne() async throws {
        for i in 0..<400 { _ = try makeDir("pad-\(i)", in: outer) }
        for name in ["alpha", "album"] { _ = try makeDir(name) }
        let m = model()

        m.edit(dir.path + "/al")
        try await settle(m)
        XCTAssertEqual(m.rows.count, 2, "precondition: the route's read landed")

        // Long enough for the parent's read to land several times over.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            m.cache?.parent, dir.path,
            "the parent's read landed second and took the slot with it"
        )
        // And the consequence, which is the part a reader would notice:
        // narrowing still answers from memory instead of the disk.
        m.edit(dir.path + "/alp")
        XCTAssertEqual(m.rows.map(\.relativePath), ["alpha"])
    }

    func testLeavingClearsWhatWasOffered() async throws {
        _ = try makeDir("alpha")
        let m = model()
        m.edit(dir.path + "/")
        try await settle(m)

        m.endEditing()

        XCTAssertTrue(m.rows.isEmpty)
        XCTAssertFalse(m.isEditing)
    }

    func testResettingForgetsTheCacheSoANewFolderAppears() async throws {
        let m = model()
        m.edit(dir.path + "/")
        // Nothing inside yet, so nothing is offered.
        _ = try makeDir("madeAfter")

        m.reset()
        m.beginEditing()
        m.edit(dir.path + "/")
        try await settle(m)

        XCTAssertEqual(m.rows.map(\.relativePath), ["madeAfter"])
    }

    // MARK: - Committing

    func testCommittingAPathReportsIt() throws {
        let inner = try makeDir("inner")
        var changed: [URL] = []
        let m = model { changed.append($0) }

        m.edit(inner.path)
        XCTAssertTrue(m.commit())

        XCTAssertEqual(changed.map(\.lastPathComponent), ["inner"])
        XCTAssertFalse(m.isEditing, "and the caret is handed back")
    }

    func testCommittingAFileReportsNothing() throws {
        let file = dir.appendingPathComponent("a.rb")
        try Data("x".utf8).write(to: file)
        var changed = 0
        let m = model { _ in changed += 1 }

        m.edit(file.path)

        XCTAssertFalse(m.commit())
        XCTAssertEqual(changed, 0)
        XCTAssertTrue(m.isEditing, "and stays open so the typo can be fixed")
    }

    func testCommittingSomethingThatDoesNotExistReportsNothing() {
        var changed = 0
        let m = model { _ in changed += 1 }

        m.edit(dir.path + "/nope")

        XCTAssertFalse(m.commit())
        XCTAssertEqual(changed, 0)
    }

    /// The field says what actually happened rather than what was asked for: an
    /// owner is free to canonicalise the folder, or to refuse it outright.
    func testTheFieldIsRefilledFromTheOwnerAfterACommit() throws {
        let inner = try makeDir("inner")
        var applied: URL?
        let m = FileRootFieldModel(
            route: { applied ?? self.dir },
            onCommit: { applied = $0 }
        )
        m.beginEditing()

        m.edit(inner.path)
        XCTAssertTrue(m.commit())

        XCTAssertEqual(m.field.text, inner.path)
    }

    func testRevertingPutsTheRootBack() throws {
        let m = model()
        m.edit("/somewhere/else")

        m.revert()

        XCTAssertEqual(m.field.text, dir.path)
        XCTAssertFalse(m.isEditing)
    }

    // MARK: - Tab

    func testTabCompletesFromTheSameCacheTheListUses() async throws {
        _ = try makeDir("alpha")
        let m = model()
        m.edit(dir.path + "/")
        try await settle(m)

        m.edit(dir.path + "/al")
        m.complete()

        XCTAssertEqual(m.field.text, dir.path + "/alpha/")
    }

    /// Tab answers even when nothing has been read yet, which is the reason it
    /// reads synchronously where the list does not: a keypress needs an answer
    /// now, a list is allowed to arrive.
    func testTabAnswersWithoutWaitingForTheList() throws {
        _ = try makeDir("alpha")
        let m = model()

        m.edit(dir.path + "/al")
        m.complete()

        XCTAssertEqual(m.field.text, dir.path + "/alpha/")
    }
}
