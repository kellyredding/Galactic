import XCTest

@testable import Galactic

/// The bytes written to the results file.
///
/// These are what everything other than the reader sees — Copy Path then open
/// elsewhere, a relaunch that has the file but not the run, `grep` over it — so
/// the shape is asserted rather than left to whatever the renderer happened to
/// emit.
final class FileSearchPlainTextTests: XCTestCase {

    private func line(
        _ number: Int, _ text: String, isMatch: Bool
    ) -> FileSearchLine {
        FileSearchLine(
            line: number, segments: [.init(text: text, isMatch: isMatch)]
        )
    }

    private func run(
        files: [FileSearchFileResult] = [],
        truncation: FileSearchRun.Truncation? = nil,
        skipped: [String] = [],
        indexed: Bool = true,
        caseSensitive: Bool = false
    ) -> FileSearchRun {
        FileSearchRun(
            query: FileSearchQuery(
                text: "needle", isCaseSensitive: caseSensitive, contextLines: 1
            ),
            root: "/root",
            files: files,
            filesConsidered: 1_234,
            filesScanned: 1_000,
            matchCount: files.reduce(0) { $0 + $1.matchCount },
            truncation: truncation,
            skippedNames: skipped,
            wasRootIndexed: indexed
        )
    }

    private func oneFile(
        relative: String = "src/a.swift",
        blocks: [[FileSearchLine]]? = nil,
        matchCount: Int = 1,
        truncated: Bool = false
    ) -> FileSearchFileResult {
        FileSearchFileResult(
            path: "/root/" + relative,
            relativePath: relative,
            matchCount: matchCount,
            blocks: blocks
                ?? [
                    [
                        line(2, "before", isMatch: false),
                        line(3, "let needle = 1", isMatch: true),
                    ]
                ],
            wasTruncated: truncated
        )
    }

    func testTheHeaderIsTheFirstLine() {
        let out = FileSearchPlainText.render(run: run())
        XCTAssertTrue(
            out.hasPrefix("Searching 1,234 files for \"needle\"")
        )
        XCTAssertTrue(out.contains("case insensitive"))
    }

    func testTheQueryIsNotEscapedHere() {
        let r = FileSearchRun(
            query: FileSearchQuery(
                text: "a < b", isCaseSensitive: false, contextLines: 0
            ),
            root: "/root", files: [], filesConsidered: 1, filesScanned: 1,
            matchCount: 0, truncation: nil, skippedNames: []
        )
        let out = FileSearchPlainText.render(run: r)
        XCTAssertTrue(
            out.contains("\"a < b\""), "this is text, not markup"
        )
    }

    func testAPathIsFollowedByItsLines() {
        let out = FileSearchPlainText.render(run: run(files: [oneFile()]))
        XCTAssertTrue(out.contains("src/a.swift:"))
        XCTAssertTrue(out.contains("let needle = 1"))
    }

    /// The colon marks a matching line and a space marks context, so the
    /// distinction survives into a file that has no styling to carry it.
    func testAMatchingLineIsMarkedAndContextIsNot() {
        let out = FileSearchPlainText.render(run: run(files: [oneFile()]))
        XCTAssertTrue(out.contains("   3: let needle = 1"))
        XCTAssertTrue(out.contains("   2  before"))
    }

    func testLineNumbersAreRightAligned() {
        let file = oneFile(
            blocks: [
                [
                    line(9, "nine", isMatch: true),
                    line(100, "hundred", isMatch: true),
                ]
            ]
        )
        let out = FileSearchPlainText.render(run: run(files: [file]))
        XCTAssertTrue(out.contains("   9: nine"))
        XCTAssertTrue(out.contains(" 100: hundred"))
    }

    func testASecondBlockIsSeparatedByABlankLine() {
        let file = oneFile(
            blocks: [
                [line(3, "first", isMatch: true)],
                [line(90, "second", isMatch: true)],
            ]
        )
        let out = FileSearchPlainText.render(run: run(files: [file]))
        let lines = out.components(separatedBy: "\n")
        let firstIndex = try? XCTUnwrap(
            lines.firstIndex { $0.contains("first") }
        )
        let secondIndex = try? XCTUnwrap(
            lines.firstIndex { $0.contains("second") }
        )
        if let a = firstIndex, let b = secondIndex {
            XCTAssertEqual(
                lines[(a + 1)..<b].filter { $0.isEmpty }.count, 1,
                "one blank line marks the gap in the file"
            )
        }
    }

    func testTruncationIsStated() {
        let out = FileSearchPlainText.render(
            run: run(truncation: .matchCap(2_000))
        )
        XCTAssertTrue(out.contains("Stopped at 2,000 matches"))
    }

    func testThePerFileCapIsStated() {
        let out = FileSearchPlainText.render(
            run: run(truncation: .fileCap(50))
        )
        XCTAssertTrue(out.contains("more than 50 matches"))
    }

    func testSkippedNamesAreStated() {
        let out = FileSearchPlainText.render(run: run(skipped: ["log", "tmp"]))
        XCTAssertTrue(out.contains("Not searched: log, tmp"))
    }

    func testNoMatchesIsSaid() {
        XCTAssertTrue(FileSearchPlainText.render(run: run()).contains("No matches."))
    }

    func testAnUnindexedRootSaysSo() {
        let out = FileSearchPlainText.render(run: run(indexed: false))
        XCTAssertTrue(out.contains("not indexed yet"))
        XCTAssertFalse(out.contains("No matches."))
    }

    func testCaseSensitivityIsStated() {
        let out = FileSearchPlainText.render(run: run(caseSensitive: true))
        XCTAssertTrue(out.contains("case sensitive"))
    }

    func testItEndsWithANewline() {
        XCTAssertTrue(
            FileSearchPlainText.render(run: run(files: [oneFile()]))
                .hasSuffix("\n")
        )
    }

    /// It has to load back through `ReaderFile`, or the tab it is written for
    /// cannot open.
    func testTheOutputIsTextByTheReadersOwnTest() {
        let out = FileSearchPlainText.render(run: run(files: [oneFile()]))
        let bytes = Array(out.utf8)
        XCTAssertTrue(
            FileSearchScanner.withBytes(bytes) {
                FileSearchScanner.isProbablyText($0)
            }
        )
    }
}
