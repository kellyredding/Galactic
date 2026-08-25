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

    /// **A generated document is named, not located.**
    ///
    /// Search results sit under a per-owner directory — a constant in a
    /// single-session application and a session id in one with several — so
    /// spelling the path out labels the same tab differently in each app, and
    /// in one of them with a raw identifier a reader cannot act on.
    func testAGeneratedDocumentIsLabelledByNameAlone() {
        let results = FileIndexPaths.root
            .appendingPathComponent("search")
            .appendingPathComponent("79D0F28B-9BC4-45EB-9817-4CAA9D2AF4D0")
            .appendingPathComponent("Find Results")

        XCTAssertEqual(
            FileTabLabel.tiers(
                for: results, root: URL(fileURLWithPath: "/tmp/project")
            ),
            ["Find Results"],
            "one tier, so no width of strip can widen it back into a path"
        )
    }

    func testTheWidestTierIsRelativeToTheRoot() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/src/models/user.rb"), root: root
        )

        XCTAssertEqual(tiers.first, "src/models/user.rb")
    }

    /// Widest first, one folder initialled per step, ending at the filename.
    ///
    /// **`models/user.rb` used to be one of these and is not any more.** Dropping
    /// the leading folders outright threw away how deep the file sits, which is
    /// the thing initialling them was invented to keep — `s/models/user.rb` says
    /// there is one folder above and this is not the top, and it costs two
    /// characters to say it. Losing that tier also means each step is strictly
    /// narrower than the one before, so the order is reliable rather than
    /// coincidental.
    func testTiersNarrowOneFolderAtATimeAndEndAtTheFilename() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/src/models/user.rb"), root: root
        )

        XCTAssertEqual(
            tiers,
            [
                "src/models/user.rb",
                "s/models/user.rb",
                "s/m/user.rb",
                "user.rb",
            ]
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

    /// A tier per folder, unwinding from the right.
    ///
    /// **The four coarse tiers this replaced were a cliff.** From every folder
    /// initialled, the only step up was the entire path — so a row with a little
    /// room left over could not buy anything with it, and a tab sat squashed
    /// while the row it was in looked half empty. One folder at a time gives the
    /// fit something it can afford.
    ///
    /// From the right because the folders nearest the file are the ones that say
    /// which file it is.
    func testATierPerFolderUnwoundFromTheRight() {
        let tiers = FileTabLabel.tiers(
            for: url("/work/project/app/models/live/api.rb"), root: root
        )

        XCTAssertEqual(
            tiers,
            [
                "app/models/live/api.rb",
                "a/models/live/api.rb",
                "a/m/live/api.rb",
                "a/m/l/api.rb",
                "api.rb",
            ]
        )
    }

    /// Deep paths get proportionally more steps, which is the point: the deeper
    /// the file, the more the old cliff cost.
    func testADeeperPathOffersMoreSteps() {
        let shallow = FileTabLabel.tiers(
            for: url("/work/project/src/a.rb"), root: root
        )
        // Real folder names, because single-character ones initial to
        // themselves and every step would dedupe into one.
        let deep = FileTabLabel.tiers(
            for: url("/work/project/app/models/live/nested/api.rb"), root: root
        )

        XCTAssertGreaterThan(deep.count, shallow.count)
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
