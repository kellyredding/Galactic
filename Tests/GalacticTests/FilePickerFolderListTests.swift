import XCTest

@testable import Galactic

/// The folders a partly-typed path is choosing between.
///
/// Children are supplied rather than read, so every rule here is exercised
/// without a filesystem — which is the point of the split.
final class FilePickerFolderListTests: XCTestCase {

    private let home = NSHomeDirectory()

    // MARK: - What the separator decides

    /// A finished segment asks about what is inside, so everything is offered.
    func testATrailingSeparatorOffersEveryChild() {
        let rows = FilePickerFolderList.rows(
            for: "~/projects/",
            children: [
                "\(home)/projects/alpha",
                "\(home)/projects/beta",
            ]
        )

        XCTAssertEqual(rows.map(\.relativePath), ["alpha", "beta"])
    }

    /// A partial segment narrows to it.
    func testAPartialSegmentFiltersByPrefix() {
        let rows = FilePickerFolderList.rows(
            for: "~/pro",
            children: [
                "\(home)/projects",
                "\(home)/prototypes",
                "\(home)/Documents",
            ]
        )

        XCTAssertEqual(rows.map(\.relativePath), ["projects", "prototypes"])
    }

    // MARK: - What a row is

    /// The name alone, because the field above already shows the parent.
    /// Repeating the path in every row would push the part that differs off the
    /// right-hand side.
    func testARowDisplaysTheFolderNameAlone() {
        let rows = FilePickerFolderList.rows(
            for: "~/pro", children: ["\(home)/projects"]
        )

        XCTAssertEqual(rows.first?.relativePath, "projects")
        XCTAssertEqual(rows.first?.url.path, "\(home)/projects")
    }

    /// The provenance that routes activation to a re-root instead of an open.
    /// A folder row reaching `onOpen` would hand a directory to the reader.
    func testEveryRowIsAFolder() {
        let rows = FilePickerFolderList.rows(
            for: "~/projects/",
            children: ["\(home)/projects/alpha", "\(home)/projects/beta"]
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.source == .folder })
    }

    // MARK: - Order

    /// Finder's order, not the byte order. `Photo9` before `Photo10` because a
    /// reader scanning the list expects counting, and `apple` beside `Apple`
    /// because two alphabets read as two lists.
    ///
    /// This test is why `FilePickerFolderList.precedes` spells the comparator
    /// out instead of calling `localizedStandardCompare`: written against the
    /// localized one, it passed in the app and failed here, because the numeric
    /// handling depends on a locale the test bundle does not run under.
    func testTheOrderIsNaturalRatherThanByteOrder() {
        let rows = FilePickerFolderList.rows(
            for: "~/shots/",
            children: [
                "\(home)/shots/Photo10",
                "\(home)/shots/Photo9",
                "\(home)/shots/apple",
                "\(home)/shots/Apple",
            ]
        )

        XCTAssertEqual(
            rows.map(\.relativePath),
            ["apple", "Apple", "Photo9", "Photo10"],
            "byte order would give Apple, Photo10, Photo9, apple"
        )
    }

    /// The comparator itself, pinned directly — the ordering above is the
    /// consequence, and a failure here says which of the two properties broke.
    func testTheComparatorFoldsCaseAndCountsDigitRuns() {
        XCTAssertTrue(FilePickerFolderList.precedes("Photo9", "Photo10"))
        XCTAssertFalse(FilePickerFolderList.precedes("Photo10", "Photo9"))
        XCTAssertTrue(FilePickerFolderList.precedes("apple", "Banana"))
        XCTAssertTrue(FilePickerFolderList.precedes("Apple", "banana"))
    }

    // MARK: - Bounds

    func testTheListIsCapped() {
        let children = (1...50).map { "\(home)/many/folder\($0)" }

        XCTAssertEqual(
            FilePickerFolderList.rows(
                for: "~/many/", children: children, limit: 10
            )
            .count,
            10
        )
    }

    func testNoChildrenIsNoRows() {
        XCTAssertTrue(
            FilePickerFolderList.rows(for: "~/pro", children: []).isEmpty
        )
    }

    /// The list answers about paths only. A filter is the corpus's question,
    /// and answering it here would show folders to someone searching for files.
    func testAFilterProducesNoRows() {
        XCTAssertTrue(
            FilePickerFolderList.rows(
                for: "usermodel", children: ["\(home)/usermodels"]
            )
            .isEmpty
        )
    }
}
