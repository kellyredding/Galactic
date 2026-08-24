import XCTest

@testable import Galactic

/// The root field's own rules.
///
/// `FileRootInputTests` covers path resolution and completion; what only this
/// file covers is what the *field* adds on top — filling itself from a root,
/// treating its content as a path without asking whether it is one, and the
/// difference between the folder you picked and the folder you named.
final class FileRootFieldTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-field-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func makeDir(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    // MARK: - Filling from a root

    func testResettingAbbreviatesAHomePath() {
        var field = FileRootField()
        field.reset(to: URL(fileURLWithPath: NSHomeDirectory() + "/projects/app"))
        XCTAssertEqual(field.text, "~/projects/app")
    }

    func testResettingToHomeItselfIsJustTheTilde() {
        var field = FileRootField()
        field.reset(to: URL(fileURLWithPath: NSHomeDirectory()))
        XCTAssertEqual(field.text, "~")
    }

    /// A sibling of home is not inside it, and a prefix test without the
    /// separator would claim otherwise.
    func testAPathMerelySharingHomesPrefixIsNotAbbreviated() {
        var field = FileRootField()
        let sibling = NSHomeDirectory() + "-backup/app"
        field.reset(to: URL(fileURLWithPath: sibling))
        XCTAssertEqual(field.text, sibling)
    }

    func testResettingOutsideHomeKeepsTheAbsolutePath() {
        var field = FileRootField()
        field.reset(to: URL(fileURLWithPath: "/opt/tools"))
        XCTAssertEqual(field.text, "/opt/tools")
    }

    func testResettingToNothingEmptiesTheField() {
        var field = FileRootField(text: "~/somewhere")
        field.reset(to: nil)
        XCTAssertEqual(field.text, "")
    }

    func testResettingDropsAnyPick() {
        var field = FileRootField()
        field.moveSelection(by: 1, rowCount: 3)
        XCTAssertNotNil(field.selection)

        field.reset(to: URL(fileURLWithPath: "/opt"))

        XCTAssertNil(field.selection)
    }

    // MARK: - The field is a path

    func testAnAbsolutePathExpandsToItself() {
        let field = FileRootField(text: "/opt/tools")
        XCTAssertEqual(field.expandedPath(route: nil), "/opt/tools")
    }

    func testATildeExpandsToHome() {
        let field = FileRootField(text: "~/projects")
        XCTAssertEqual(
            field.expandedPath(route: nil), NSHomeDirectory() + "/projects"
        )
    }

    /// The difference from the search field: `src` is a path here, because this
    /// field has no other job for it to be.
    func testRelativeTextResolvesAgainstTheRoute() {
        let field = FileRootField(text: "src")
        XCTAssertEqual(
            field.expandedPath(route: "/work/app"), "/work/app/src"
        )
    }

    func testRelativeTextWithNoRouteMeansNothing() {
        let field = FileRootField(text: "src")
        XCTAssertNil(field.expandedPath(route: nil))
    }

    func testDotDotClimbsFromTheRoute() {
        let field = FileRootField(text: "../other")
        XCTAssertEqual(
            field.expandedPath(route: "/work/app"), "/work/other"
        )
    }

    func testEmptyTextMeansNothing() {
        XCTAssertNil(FileRootField(text: "").expandedPath(route: "/work"))
        XCTAssertNil(FileRootField(text: "   ").expandedPath(route: "/work"))
    }

    // MARK: - Which directory is being chosen from

    func testAPartialSegmentChoosesAmongItsParentsChildren() {
        let field = FileRootField(text: "/work/app/sr")
        XCTAssertEqual(field.candidateParent(route: nil), "/work/app")
    }

    /// The trailing separator is the whole distinction, and it cannot be left to
    /// `deletingLastPathComponent`, which answers the same for both.
    func testAFinishedSegmentChoosesAmongItsOwnChildren() {
        let field = FileRootField(text: "/work/app/")
        XCTAssertEqual(field.candidateParent(route: nil), "/work/app")
    }

    func testTheRootDirectoryIsItsOwnParent() {
        let field = FileRootField(text: "/")
        XCTAssertEqual(field.candidateParent(route: nil), "/")
    }

    // MARK: - Completion

    func testCompletionFinishesAnUnambiguousSegment() throws {
        try makeDir("sources")
        let field = FileRootField(text: dir.path + "/sou")
        let completed = field.completion(
            directories: FileDirectoryReader.childDirectories(of: dir.path),
            route: nil
        )
        XCTAssertEqual(completed, dir.path + "/sources/")
    }

    func testCompletionStopsAtTheSharedPrefixWhenAmbiguous() throws {
        try makeDir("sources")
        try makeDir("sounds")
        let field = FileRootField(text: dir.path + "/so")
        let completed = field.completion(
            directories: FileDirectoryReader.childDirectories(of: dir.path),
            route: nil
        )
        XCTAssertEqual(
            completed, dir.path + "/sou",
            "one press extends as far as they agree and no further"
        )
    }

    func testCompletionRefusesWhenNothingMatches() throws {
        try makeDir("sources")
        let field = FileRootField(text: dir.path + "/zzz")
        XCTAssertNil(
            field.completion(
                directories: FileDirectoryReader.childDirectories(of: dir.path),
                route: nil
            )
        )
    }

    /// The tilde has to survive completion, or one Tab rewrites the field into
    /// an absolute path the reader did not type.
    func testCompletionKeepsTheTildeSpelling() throws {
        let home = NSHomeDirectory()
        let children = FileDirectoryReader.childDirectories(of: home)
        guard let first = children.sorted().first else {
            throw XCTSkip("no directories in home on this machine")
        }
        let name = (first as NSString).lastPathComponent
        let field = FileRootField(text: "~/" + String(name.prefix(1)))

        let completed = field.completion(directories: children, route: nil)

        if let completed {
            XCTAssertTrue(
                completed.hasPrefix("~/"),
                "completed to \(completed), which is no longer abbreviated"
            )
        }
    }

    func testCompletionOfEmptyTextIsNothing() {
        let field = FileRootField(text: "")
        XCTAssertNil(field.completion(directories: ["/a", "/b"], route: nil))
    }

    // MARK: - Offering folders

    func testRowsNarrowToWhatIsTyped() throws {
        try makeDir("alpha")
        try makeDir("beta")
        let field = FileRootField(text: dir.path + "/al")

        let rows = field.rows(
            children: FileDirectoryReader.childDirectories(of: dir.path),
            route: nil
        )

        XCTAssertEqual(rows.map(\.relativePath), ["alpha"])
    }

    func testAFinishedSegmentOffersEverythingInside() throws {
        try makeDir("alpha")
        try makeDir("beta")
        let field = FileRootField(text: dir.path + "/")

        let rows = field.rows(
            children: FileDirectoryReader.childDirectories(of: dir.path),
            route: nil
        )

        XCTAssertEqual(rows.map(\.relativePath), ["alpha", "beta"])
    }

    // MARK: - Committing

    func testAnExplicitPickWinsOverTheText() throws {
        let alpha = try makeDir("alpha")
        let beta = try makeDir("beta")
        var field = FileRootField(text: dir.path + "/al")
        let rows = field.rows(
            children: [alpha.path, beta.path], route: nil
        )
        field.moveSelection(by: 1, rowCount: rows.count)

        XCTAssertEqual(
            field.resolved(rows: rows, route: nil)?.path, alpha.path
        )
    }

    /// Without an arrow key there is no pick, so the text is what commits —
    /// even though a list is showing and its first row would have been a
    /// plausible guess.
    func testWithNoPickTheTypedPathCommits() throws {
        let alpha = try makeDir("alpha")
        let field = FileRootField(text: dir.path)
        let rows = field.rows(children: [alpha.path], route: nil)

        XCTAssertEqual(
            field.resolved(rows: rows, route: nil)?.path, dir.path
        )
    }

    func testATrailingSeparatorStillCommits() {
        let field = FileRootField(text: dir.path + "/")
        XCTAssertEqual(field.resolved(rows: [], route: nil)?.path, dir.path)
    }

    /// The refusal that keeps a re-root from landing nowhere.
    func testAPathThatDoesNotExistCommitsNothing() {
        let field = FileRootField(text: dir.path + "/nope")
        XCTAssertNil(field.resolved(rows: [], route: nil))
    }

    func testAFileIsNotSomewhereToRootAt() throws {
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let field = FileRootField(text: file.path)

        XCTAssertNil(
            field.resolved(rows: [], route: nil),
            "a file is not a folder to browse"
        )
    }

    func testEmptyTextCommitsNothing() {
        XCTAssertNil(
            FileRootField(text: "").resolved(rows: [], route: "/work")
        )
    }

    // MARK: - Selection arithmetic

    func testTheFirstDownArrowPicksTheFirstRow() {
        var field = FileRootField()
        field.moveSelection(by: 1, rowCount: 3)
        XCTAssertEqual(field.selection, 0)
    }

    func testSelectionClampsAtBothEnds() {
        var field = FileRootField()
        field.moveSelection(by: 1, rowCount: 2)
        field.moveSelection(by: 1, rowCount: 2)
        field.moveSelection(by: 1, rowCount: 2)
        XCTAssertEqual(field.selection, 1, "no wrap at the bottom")

        field.moveSelection(by: -5, rowCount: 2)
        XCTAssertEqual(field.selection, 0, "and none at the top")
    }

    func testMovingWithNoRowsClearsThePick() {
        var field = FileRootField()
        field.moveSelection(by: 1, rowCount: 3)
        field.moveSelection(by: 1, rowCount: 0)
        XCTAssertNil(field.selection)
    }

    func testClearingDropsThePick() {
        var field = FileRootField()
        field.moveSelection(by: 1, rowCount: 3)
        field.clearSelection()
        XCTAssertNil(field.selection)
    }
}
