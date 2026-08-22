import XCTest

@testable import Galactic

/// What a file tree is showing, and in what order.
///
/// These are the rules that would otherwise live in view code, where the drag
/// defects and the tooltip's ordering bug both hid: laziness, the two expansion
/// sets, and what a filter does to a tree. All of them are reachable here as
/// plain calls, with no filesystem and no view.
final class FileTreeOutlineTests: XCTestCase {

    private let root = "/work"

    /// A fixed tree, so a provider can answer from it without touching disk.
    private let tree: [String: [FileTreeOutline.Entry]] = [
        "/work": [
            .init(path: "/work/readme.md", isDirectory: false),
            .init(path: "/work/src", isDirectory: true),
            .init(path: "/work/docs", isDirectory: true),
        ],
        "/work/src": [
            .init(path: "/work/src/main.swift", isDirectory: false),
            .init(path: "/work/src/deep", isDirectory: true),
        ],
        "/work/src/deep": [
            .init(path: "/work/src/deep/inner.swift", isDirectory: false)
        ],
        "/work/docs": [
            .init(path: "/work/docs/guide.md", isDirectory: false)
        ],
    ]

    /// Ordered, because that is the provider's contract — the flatten consumes
    /// the order it is given rather than sorting on every draw. See
    /// `FileTreeOutline.rows(root:children:)` for the measurement behind that.
    private func children(_ path: String) -> [FileTreeOutline.Entry] {
        (tree[path] ?? []).sorted(by: FileTreeOutline.precedes)
    }

    private func paths(_ rows: [FileTreeOutline.Row]) -> [String] {
        rows.map(\.path)
    }

    // MARK: - Laziness

    /// A closed folder costs nothing: the provider is never asked about it.
    /// This is the whole of the laziness, and it is a property of the model
    /// rather than of the view that draws it.
    func testAClosedDirectoryIsNeverAskedForItsChildren() {
        var asked: [String] = []
        let outline = FileTreeOutline(expandedByReader: [root])

        _ = outline.rows(root: root) { path in
            asked.append(path)
            return self.children(path)
        }

        XCTAssertEqual(asked, [root], "src and docs were never opened")
    }

    func testAClosedRootShowsOnlyItself() {
        let outline = FileTreeOutline()

        let rows = outline.rows(root: root, children: children)

        XCTAssertEqual(paths(rows), [root])
        XCTAssertFalse(rows[0].isExpanded)
        XCTAssertTrue(rows[0].isDirectory, "the root is collapsible")
    }

    // MARK: - Order

    /// Folders before files, each in Finder order. Finder interleaves them; a
    /// tree reads better grouped.
    ///
    /// The rule lives in `precedes` and is applied where a directory is read, so
    /// this asserts the comparator through a provider that uses it — which is
    /// exactly how the presenter uses it.
    func testFoldersComeBeforeFilesEachInFinderOrder() {
        let outline = FileTreeOutline(expandedByReader: [root])

        let rows = outline.rows(root: root, children: children)

        XCTAssertEqual(
            paths(rows),
            [
                "/work",
                "/work/docs",  // folders, alphabetically
                "/work/src",
                "/work/readme.md",  // then files
            ]
        )
    }

    func testDigitRunsAreComparedAsNumbers() {
        let unordered: [FileTreeOutline.Entry] = [
            .init(path: "/n/Photo10.png", isDirectory: false),
            .init(path: "/n/Photo9.png", isDirectory: false),
        ]

        XCTAssertEqual(
            unordered.sorted(by: FileTreeOutline.precedes).map(\.path),
            ["/n/Photo9.png", "/n/Photo10.png"]
        )
    }

    /// **The flatten does not sort.** It draws the order it was handed, which is
    /// what lets the sort happen once per directory read instead of once per
    /// draw — measured at 194 ms a draw for a real 2,392-entry directory,
    /// against 0.1 ms once this moved.
    func testTheFlattenDrawsTheOrderItIsGiven() {
        let outline = FileTreeOutline(expandedByReader: ["/n"])

        let rows = outline.rows(root: "/n") { _ in
            [
                .init(path: "/n/zebra.md", isDirectory: false),
                .init(path: "/n/apple.md", isDirectory: false),
            ]
        }

        XCTAssertEqual(
            paths(rows), ["/n", "/n/zebra.md", "/n/apple.md"],
            "given out of order, drawn out of order — the caller orders"
        )
    }

    // MARK: - Depth and nesting

    func testDepthIsOnePerLevelBelowTheRoot() {
        let outline = FileTreeOutline(
            expandedByReader: [root, "/work/src", "/work/src/deep"]
        )

        let rows = outline.rows(root: root, children: children)
        let byPath = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.path, $0.depth) }
        )

        XCTAssertEqual(byPath["/work"], 0)
        XCTAssertEqual(byPath["/work/src"], 1)
        XCTAssertEqual(byPath["/work/src/deep"], 2)
        XCTAssertEqual(byPath["/work/src/deep/inner.swift"], 3)
    }

    /// Depth-first: a folder's contents sit directly under it, not after its
    /// siblings.
    func testAnOpenFoldersContentsFollowItImmediately() {
        let outline = FileTreeOutline(expandedByReader: [root, "/work/docs"])

        XCTAssertEqual(
            paths(outline.rows(root: root, children: children)),
            [
                "/work",
                "/work/docs",
                "/work/docs/guide.md",
                "/work/src",
                "/work/readme.md",
            ]
        )
    }

    func testARowKnowsItsOwnName() {
        let outline = FileTreeOutline(expandedByReader: [root])
        let rows = outline.rows(root: root, children: children)

        XCTAssertEqual(rows.map(\.name), ["work", "docs", "src", "readme.md"])
    }

    // MARK: - Filtering

    func testAFilterRevealsEveryAncestorOfAMatch() {
        let outline = FileTreeOutline()

        let rows = outline.rows(
            root: root, matching: [.init(path: "/work/src/deep/inner.swift")]
        )

        XCTAssertEqual(
            paths(rows),
            ["/work", "/work/src", "/work/src/deep", "/work/src/deep/inner.swift"]
        )
    }

    /// Non-matching branches are simply absent — a filter is a visibility
    /// question, not a ranking one.
    func testAFilterHidesBranchesWithNoMatch() {
        let outline = FileTreeOutline()

        let rows = outline.rows(root: root, matching: [.init(path: "/work/docs/guide.md")])

        XCTAssertFalse(paths(rows).contains("/work/src"))
    }

    func testFilteredDirectoriesAreOpenAndMarkedAsRevealed() {
        let outline = FileTreeOutline()

        let rows = outline.rows(
            root: root, matching: [.init(path: "/work/src/deep/inner.swift")]
        )
        let src = rows.first { $0.path == "/work/src" }

        XCTAssertEqual(src?.isExpanded, true)
        XCTAssertEqual(src?.isRevealedByFilter, true)
        XCTAssertEqual(
            rows.first?.isRevealedByFilter, false,
            "the root is where the reader already is"
        )
    }

    func testFilteredRowsKeepFoldersBeforeFiles() {
        let outline = FileTreeOutline()

        let rows = outline.rows(
            root: root,
            matching: [
                .init(path: "/work/readme.md"),
                .init(path: "/work/src/main.swift"),
            ]
        )

        XCTAssertEqual(
            paths(rows),
            ["/work", "/work/src", "/work/src/main.swift", "/work/readme.md"]
        )
    }

    /// **The reason there are two expansion sets.** A filter opens folders to
    /// show what matched; clearing it must give back the tree the reader had,
    /// neither stranding the filter's folders open nor closing the reader's.
    func testAFilterLeavesTheReadersOwnExpansionsUntouched() {
        var outline = FileTreeOutline(expandedByReader: [root, "/work/docs"])

        _ = outline.rows(root: root, matching: [.init(path: "/work/src/deep/inner.swift")])

        XCTAssertEqual(
            outline.expandedByReader, [root, "/work/docs"],
            "the filter wrote nothing"
        )
        XCTAssertEqual(
            paths(outline.rows(root: root, children: children)),
            [
                "/work", "/work/docs", "/work/docs/guide.md", "/work/src",
                "/work/readme.md",
            ],
            "and clearing it returns exactly the tree from before"
        )
    }

    /// A path outside the root cannot climb to it, and must not be walked as
    /// though it could.
    func testAMatchOutsideTheRootIsIgnored() {
        let outline = FileTreeOutline()

        let rows = outline.rows(root: root, matching: [.init(path: "/elsewhere/x.swift")])

        XCTAssertEqual(paths(rows), [root])
    }

    // MARK: - Highlighting

    /// The matcher answers in offsets along a whole relative path; a tree draws
    /// one name per row. So each offset is charged to the segment it landed in
    /// and rewritten against that segment — without which every row would
    /// highlight from its own front, which is the wrong letters everywhere but
    /// the first.
    func testAMatchIsCutUpByPathSegment() {
        let outline = FileTreeOutline()
        // "src/deep/inner.swift", highlighting "s" of src, "d" of deep, and
        // "i" of inner: offsets 0, 4 and 9.
        let rows = outline.rows(
            root: root,
            matching: [
                .init(path: "/work/src/deep/inner.swift", highlighted: [0, 4, 9])
            ]
        )
        let byPath = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.path, $0.matchedOffsets) }
        )

        XCTAssertEqual(byPath["/work/src"], [0], "the s of src")
        XCTAssertEqual(byPath["/work/src/deep"], [0], "the d of deep")
        XCTAssertEqual(byPath["/work/src/deep/inner.swift"], [0], "the i of inner")
        XCTAssertEqual(byPath["/work"], [], "the root is not part of the match")
    }

    /// An offset landing mid-segment keeps its position within that name.
    func testAnOffsetKeepsItsPlaceWithinItsOwnName() {
        let outline = FileTreeOutline()
        // "src/deep/inner.swift": offset 6 is the second `e` of `deep`.
        let rows = outline.rows(
            root: root,
            matching: [
                .init(path: "/work/src/deep/inner.swift", highlighted: [6])
            ]
        )

        XCTAssertEqual(
            rows.first { $0.path == "/work/src/deep" }?.matchedOffsets, [2]
        )
    }

    /// A folder is an ancestor of many matches, and each may have landed
    /// somewhere different in its name — so the offsets are unioned rather than
    /// taken from whichever match arrived first.
    func testAFolderCollectsOffsetsFromEveryMatchUnderIt() {
        let outline = FileTreeOutline()
        let rows = outline.rows(
            root: root,
            matching: [
                .init(path: "/work/src/a.swift", highlighted: [0]),
                .init(path: "/work/src/b.swift", highlighted: [2]),
            ]
        )

        XCTAssertEqual(
            rows.first { $0.path == "/work/src" }?.matchedOffsets, [0, 2]
        )
    }

    /// Browsing highlights nothing: there is no query to have matched.
    func testBrowsedRowsCarryNoHighlight() {
        let outline = FileTreeOutline(expandedByReader: [root])

        let rows = outline.rows(root: root, children: children)

        XCTAssertTrue(rows.allSatisfy { $0.matchedOffsets.isEmpty })
    }

    // MARK: - Expansion

    func testTogglingOpensThenCloses() {
        var outline = FileTreeOutline()

        outline.toggle("/work/src")
        XCTAssertTrue(outline.isExpanded("/work/src"))

        outline.toggle("/work/src")
        XCTAssertFalse(outline.isExpanded("/work/src"))
    }
}
