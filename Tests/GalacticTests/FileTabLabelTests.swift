import XCTest

@testable import Galactic

/// What a tab is called as the strip runs out of room.
///
/// Tiers rather than truncation, so the strip gives up information in an order
/// someone chose: the root prefix first, then the shape of the directories, then
/// the directories themselves, and the filename last — never the filename.
final class FileTabLabelTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/work/project")

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    func testTheWidestTierIsRelativeToTheRoot() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/src/models/user.rb"), root: root
        )

        XCTAssertEqual(tiers.first, "src/models/user.rb")
    }

    func testTiersNarrowInOrderAndEndAtTheFilename() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/src/models/user.rb"), root: root
        )

        XCTAssertEqual(
            tiers,
            ["src/models/user.rb", "models/user.rb", "s/m/user.rb", "user.rb"],
            "widest first — and `models/user.rb` is wider than `s/m/user.rb`, "
                + "so informativeness and width are not the same ordering"
        )
    }

    /// A set may hold files from anywhere, so a file outside the root keeps an
    /// absolute path — shortened at the home directory, which is the one prefix
    /// a reader never needs to read.
    func testAFileOutsideTheRootKeepsAnAbsolutePath() {
        let tiers = FileTabLabel.tiers(
            for: url("/elsewhere/notes.md"), root: root
        )

        XCTAssertEqual(tiers.first, "/elsewhere/notes.md")
    }

    func testAFileUnderHomeShortensToTilde() {
        let home = NSHomeDirectory()
        let tiers = FileTabLabel.tiers(
            for: url("\(home)/notes/todo.md"), root: nil
        )

        XCTAssertEqual(tiers.first, "~/notes/todo.md")
    }

    func testARootWithATrailingSlashBehavesTheSame() {
        XCTAssertEqual(
            FileTabLabel.relativeOrAbbreviated(
                url("/work/project/a.rb"),
                root: URL(fileURLWithPath: "/work/project/")
            ),
            "a.rb"
        )
    }

    /// A sibling directory whose name merely starts with the root's is not
    /// inside it.
    func testAPathSharingAPrefixWithTheRootIsNotShortened() {
        XCTAssertEqual(
            FileTabLabel.relativeOrAbbreviated(
                url("/work/project-other/a.rb"), root: root
            ),
            "/work/project-other/a.rb"
        )
    }

    // MARK: - Squashing

    /// The shape of the path survives — how deep, and roughly where — which is
    /// most of what a reader reads it for once they know the file.
    func testSquashingKeepsTheFilenameAndTheDepth() {
        XCTAssertEqual(
            FileTabLabel.squashingFolders("src/models/user.rb"),
            "s/m/user.rb"
        )
    }

    /// A leading dot is the identifying character of a dotfile directory, so it
    /// keeps one more.
    func testADotDirectorySquashesToTwoCharacters() {
        XCTAssertEqual(
            FileTabLabel.squashingFolders(".github/workflows/ci.yml"),
            ".g/w/ci.yml"
        )
    }

    func testAFilenameAloneHasNothingToSquash() {
        XCTAssertEqual(FileTabLabel.squashingFolders("user.rb"), "user.rb")
    }

    func testAnAbsolutePathSquashesItsLeadingSlashHarmlessly() {
        XCTAssertEqual(
            FileTabLabel.squashingFolders("/work/project/a.rb"),
            "/w/p/a.rb"
        )
    }

    // MARK: - Ambiguity

    /// The narrowest tier is withheld when it would not identify the file. A
    /// strip showing two tabs both reading `index.ts` has told the reader
    /// nothing, which is worse than either tab being wide.
    func testABareFilenameIsNotOfferedWhenASiblingSharesIt() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/web/index.ts"),
            root: root,
            siblings: [
                url("/work/project/web/index.ts"),
                url("/work/project/api/index.ts"),
            ]
        )

        XCTAssertFalse(tiers.contains("index.ts"))
        XCTAssertEqual(
            tiers.last, "w/index.ts",
            "the narrowest offered label still says which one this is"
        )
    }

    func testABareFilenameIsOfferedWhenItIsUnique() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/web/index.ts"),
            root: root,
            siblings: [
                url("/work/project/web/index.ts"),
                url("/work/project/api/routes.ts"),
            ]
        )

        XCTAssertEqual(tiers.last, "index.ts")
    }

    /// The file itself is in the sibling list — a caller passes the whole strip
    /// — and must not be read as its own duplicate.
    func testAFileIsNotAmbiguousWithItself() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/a.rb"),
            root: root,
            siblings: [url("/work/project/a.rb")]
        )

        XCTAssertEqual(tiers, ["a.rb"])
    }

    // MARK: - Degenerate shapes

    /// No duplicates in the tier list, so `ViewThatFits` is never handed the
    /// same string twice to measure.
    func testAFileAtTheRootProducesOneTier() {
        XCTAssertEqual(
            FileTabLabel.tiers(for: url("/work/project/a.rb"), root: root),
            ["a.rb"]
        )
    }

    func testASingleDirectoryDeepProducesTwoTiers() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/src/a.rb"), root: root
        )

        XCTAssertEqual(tiers, ["src/a.rb", "s/a.rb", "a.rb"])
        XCTAssertEqual(Set(tiers).count, tiers.count, "no tier repeats")
    }

    /// The strip spells out one `ViewThatFits` child per tier, because a
    /// `ForEach` inside one is a single candidate. A fifth tier arriving here
    /// without `tierCount` moving would simply never be offered — the label
    /// would sit one notch wider than it had to, and nothing would fail.
    func testNoTierListExceedsTheCountTheStripDrawsFor() {
        let siblings = [
            url("/work/project/web/index.ts"),
            url("/work/project/worker/index.ts"),
        ]
        for path in [
            "/work/project/a.rb",
            "/work/project/src/a.rb",
            "/work/project/a/b/c/d/e.rb",
            "/work/project/web/index.ts",
            "/elsewhere/deeply/nested/f.rb",
            "/f.rb",
        ] {
            let tiers = FileTabLabel.tiers(
                for: url(path), root: root, siblings: siblings
            )
            XCTAssertLessThanOrEqual(
                tiers.count,
                FileTabLabel.tierCount,
                "\(path) offers more tiers than the strip has slots"
            )
        }
    }

    func testEveryTierListIsNonEmpty() {
        for path in [
            "/work/project/a.rb",
            "/work/project/src/a.rb",
            "/work/project/a/b/c/d/e.rb",
            "/elsewhere/f.rb",
            "/f.rb",
        ] {
            XCTAssertFalse(
                FileTabLabel.tiers(for: url(path), root: root).isEmpty,
                "\(path) must have something to call itself"
            )
        }
    }
}
