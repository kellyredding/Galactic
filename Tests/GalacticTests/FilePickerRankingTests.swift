import XCTest

@testable import Galactic

/// What the picker offers, and in what order.
///
/// Ranking is the part of a picker a reader feels most directly: putting the
/// right file second is worse than taking an extra keystroke to reach it, so
/// these pin the order rather than only the membership.
final class FilePickerRankingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// Build a real index, since `Item` computes its own relative path.
    private func index(_ relatives: [String]) throws -> [FileTreeIndex.Item] {
        for relative in relatives {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: url)
        }
        return FileTreeIndex.build(root: dir).items
    }

    private func paths(_ rows: [FilePickerItem]) -> [String] {
        rows.map(\.relativePath)
    }

    // MARK: - Matching

    func testAnEmptyQueryMatchesNothing() throws {
        let items = try index(["a.swift"])

        XCTAssertTrue(FilePickerRanking.matches(items, query: "").isEmpty)
        XCTAssertTrue(FilePickerRanking.matches(items, query: "   ").isEmpty)
    }

    /// The reason subsequence rather than contiguous terms: a reader types
    /// `usermodel` and the underscore must not refuse it.
    func testASubsequenceMatchesAcrossASeparator() throws {
        let items = try index(["src/user_model.rb"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "usermodel")),
            ["src/user_model.rb"]
        )
    }

    func testMatchingIgnoresCase() throws {
        let items = try index(["Src/UserModel.swift"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "usermodel")).count, 1
        )
    }

    func testANonMatchIsExcluded() throws {
        let items = try index(["a.swift", "b.swift"])

        XCTAssertTrue(
            FilePickerRanking.matches(items, query: "zzzz").isEmpty
        )
    }

    /// The cheap filter in front of the matcher must not change the answer, only
    /// how long it takes to get there.
    func testTheCharacterFilterDoesNotRejectARealMatch() throws {
        let items = try index(["deeply/nested/path/to/thing.swift"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "dnptt")).count,
            1,
            "every typed character appears, scattered — which is a match"
        )
    }

    // MARK: - Order

    /// A word start scores above a mere containment, which is what `/` being a
    /// word boundary in the matcher buys a path picker.
    func testASegmentStartOutranksAContainment() throws {
        let items = try index(["src/models/user.rb", "lib/abuser.rb"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "user")).first,
            "src/models/user.rb"
        )
    }

    /// Between equal scores, the shorter path — a match in a short path is more
    /// often the one meant.
    func testAShorterPathWinsATie() throws {
        let items = try index(["a.rb", "deep/deeper/deepest/a.rb"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "a.rb")).first,
            "a.rb"
        )
    }

    /// And alphabetically below that, so the same query twice does not shuffle.
    func testTheOrderIsStableForIdenticalQueries() throws {
        let items = try index(["b/x.rb", "a/x.rb", "c/x.rb"])

        let first = paths(FilePickerRanking.matches(items, query: "x.rb"))
        let second = paths(FilePickerRanking.matches(items, query: "x.rb"))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["a/x.rb", "b/x.rb", "c/x.rb"])
    }

    func testResultsAreCapped() throws {
        let items = try index((0..<30).map { "f\($0)x.swift" })

        XCTAssertEqual(
            FilePickerRanking.matches(items, query: "x", limit: 5).count, 5
        )
    }

    // MARK: - Highlighting

    /// Offsets index the displayed string, because that is what gets highlighted.
    func testMatchedOffsetsIndexTheDisplayedPath() throws {
        let items = try index(["src/a.rb"])

        let row = FilePickerRanking.matches(items, query: "src").first
        XCTAssertEqual(row?.matchedOffsets, [0, 1, 2])
        XCTAssertEqual(row?.relativePath, "src/a.rb")
    }

    func testAMatchedRowSaysItWasMatched() throws {
        let items = try index(["a.rb"])

        XCTAssertEqual(
            FilePickerRanking.matches(items, query: "a").first?.source, .matched
        )
    }

    /// Full path, not basename. A stack keyed on a basename recycles rows
    /// wrongly the moment two files share a name, which in a repository is
    /// immediately.
    func testIdentityIsTheFullPath() throws {
        let items = try index(["a/x.rb", "b/x.rb"])
        let rows = FilePickerRanking.matches(items, query: "x.rb")

        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    // MARK: - The empty query

    /// Closed first: closing is deliberate, and reopening is the commonest
    /// reason to come here at all.
    func testTheEmptyListOffersClosedFilesBeforeRecents() {
        let root = URL(fileURLWithPath: "/work")
        var stack = ClosedTabStack()
        stack.push(url: URL(fileURLWithPath: "/work/closed.rb"), row: 0)

        let rows = FilePickerRanking.emptyQueryList(
            closed: stack.entries,
            recent: [URL(fileURLWithPath: "/work/recent.rb")],
            root: root
        )

        XCTAssertEqual(paths(rows), ["closed.rb", "recent.rb"])
        XCTAssertEqual(rows.map(\.source), [.closed, .recent])
    }

    /// Listed once, as closed — the stronger signal of the two.
    func testAFileInBothListsAppearsOnceAsClosed() {
        let root = URL(fileURLWithPath: "/work")
        let both = URL(fileURLWithPath: "/work/both.rb")
        var stack = ClosedTabStack()
        stack.push(url: both, row: 0)

        let rows = FilePickerRanking.emptyQueryList(
            closed: stack.entries, recent: [both], root: root
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.source, .closed)
    }

    func testTheEmptyListIsCapped() {
        let root = URL(fileURLWithPath: "/work")
        var stack = ClosedTabStack()
        for i in 0..<40 {
            stack.push(url: URL(fileURLWithPath: "/work/f\(i).rb"), row: 0)
        }

        XCTAssertEqual(
            FilePickerRanking.emptyQueryList(
                closed: stack.entries, recent: [], root: root, limit: 20
            ).count,
            20
        )
    }

    func testNothingClosedAndNothingRecentIsAnEmptyList() {
        XCTAssertTrue(
            FilePickerRanking.emptyQueryList(
                closed: [], recent: [], root: URL(fileURLWithPath: "/work")
            ).isEmpty
        )
    }

    /// An offered row has nothing highlighted, because nothing was typed.
    func testOfferedRowsCarryNoHighlight() {
        var stack = ClosedTabStack()
        stack.push(url: URL(fileURLWithPath: "/work/a.rb"), row: 0)

        let rows = FilePickerRanking.emptyQueryList(
            closed: stack.entries, recent: [],
            root: URL(fileURLWithPath: "/work")
        )

        XCTAssertTrue(rows.first?.matchedOffsets.isEmpty == true)
    }

    // MARK: - Whitespace is a gap

    /// The bug this closes was total, not partial: a space went into the
    /// necessary-condition set, no path contained one, and every candidate was
    /// rejected before being scored. Any query with a space answered "no file
    /// matches" over a tree full of them.
    func testASpaceSeparatedQueryMatchesInOrder() throws {
        let items = try index([
            "projects/kellyredding/galaxy/README.md",
            "projects/other/notes.md",
        ])

        let rows = FilePickerRanking.matches(items, query: "projects kelly")

        XCTAssertEqual(
            paths(rows), ["projects/kellyredding/galaxy/README.md"]
        )
    }

    /// Ordered, because typing fragments in the order you remember them is what
    /// the space means.
    func testReversedFragmentsAreNotAMatch() throws {
        let items = try index(["projects/kellyredding/galaxy/README.md"])

        XCTAssertFalse(
            FilePickerRanking.matches(items, query: "projects galaxy").isEmpty
        )
        XCTAssertTrue(
            FilePickerRanking.matches(items, query: "galaxy projects").isEmpty
        )
    }

    /// A space in the query and a space in the filename are the same gap.
    func testAFilenameContainingASpaceStillAnswersToItsWords() throws {
        let items = try index(["Desktop/AI prompts.txt"])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "ai prompts")),
            ["Desktop/AI prompts.txt"]
        )
    }

    /// Spelling one query with and without spaces asks the same question.
    func testSpacesDoNotChangeWhatIsFound() throws {
        let items = try index([
            "projects/kellyredding/galaxy/README.md",
            "projects/kellyredding/conduit/LICENSE",
        ])

        XCTAssertEqual(
            paths(FilePickerRanking.matches(items, query: "proj kelly gal")),
            paths(FilePickerRanking.matches(items, query: "projkellygal"))
        )
    }

    func testAQueryOfOnlySpacesFindsNothing() throws {
        let items = try index(["projects/a.rb"])

        XCTAssertTrue(FilePickerRanking.matches(items, query: "   ").isEmpty)
    }
}
