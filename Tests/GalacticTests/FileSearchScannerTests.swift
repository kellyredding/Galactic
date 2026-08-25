import XCTest

@testable import Galactic

/// The literal matcher and the line arithmetic around it.
///
/// Everything here is bytes in, values out — no filesystem, no corpus, no
/// concurrency. The engine's job is to find files and hand their bytes over;
/// every rule about *what a match is* lives in this file so it can be asserted
/// from a string literal.
final class FileSearchScannerTests: XCTestCase {

    private func offsets(
        _ haystack: String,
        _ needle: String,
        caseSensitive: Bool = true,
        limit: Int = 1_000
    ) -> (offsets: [Int], wasTruncated: Bool) {
        FileSearchScanner.withBytes(Array(haystack.utf8)) { bytes in
            FileSearchScanner.matchOffsets(
                in: bytes,
                needle: Array(needle.utf8),
                isCaseSensitive: caseSensitive,
                limit: limit
            )
        }
    }

    private func blocks(
        _ haystack: String,
        _ needle: String,
        context: Int,
        caseSensitive: Bool = true
    ) -> [[FileSearchLine]] {
        FileSearchScanner.withBytes(Array(haystack.utf8)) { bytes in
            let found = FileSearchScanner.matchOffsets(
                in: bytes,
                needle: Array(needle.utf8),
                isCaseSensitive: caseSensitive,
                limit: 1_000
            )
            return FileSearchScanner.lines(
                in: bytes,
                matchOffsets: found.offsets,
                needleLength: Array(needle.utf8).count,
                contextLines: context
            )
        }
    }

    // MARK: - Is this text

    func testPlainTextIsText() {
        XCTAssertTrue(
            FileSearchScanner.withBytes(Array("let x = 1\n".utf8)) {
                FileSearchScanner.isProbablyText($0)
            }
        )
    }

    func testANulInTheWindowIsNotText() {
        var bytes = Array("binary".utf8)
        bytes.append(0)
        XCTAssertFalse(
            FileSearchScanner.withBytes(bytes) {
                FileSearchScanner.isProbablyText($0)
            }
        )
    }

    /// The window is the whole rule, and it is the reader's window. A NUL
    /// beyond it makes a file no less openable, so it must make it no less
    /// searchable — otherwise results and the reader disagree about one file.
    func testANulBeyondTheWindowIsStillText() {
        var bytes = Array(repeating: UInt8(65), count: ReaderFile.sniffWindow)
        bytes.append(0)
        XCTAssertTrue(
            FileSearchScanner.withBytes(bytes) {
                FileSearchScanner.isProbablyText($0)
            }
        )
    }

    func testEmptyBytesAreText() {
        XCTAssertTrue(
            FileSearchScanner.withBytes([]) {
                FileSearchScanner.isProbablyText($0)
            }
        )
    }

    // MARK: - Finding the needle

    // MARK: - Long lines
    //
    // A line is not a bounded thing, and the results page pays for treating it
    // as one. A minified bundle is a single line of several megabytes, and a
    // common word matches inside it: a search for "README" over 58,086 files
    // produced 8.2 MB across 1,063 result lines — past the reader's own size
    // cap, so the page this app had just written could not be opened by it and
    // went to the system instead.

    func testAnEnormousLineIsWindowedAroundItsMatch() {
        let filler = String(repeating: "x", count: 5_000)
        let result = blocks(filler + "README" + filler, "README", context: 0)
        let text = result.first?.first?.text ?? ""

        XCTAssertLessThan(
            text.utf8.count,
            FileSearchScanner.maxLineBytes + 32,
            "the window bounds what one line can contribute"
        )
        XCTAssertTrue(
            text.contains("README"), "and keeps the reason the line is here"
        )
        XCTAssertTrue(text.hasPrefix("…"), "elision is visible at both ends")
        XCTAssertTrue(text.hasSuffix("…"))
    }

    /// **A line can match more than once, and the window keeps only some of
    /// them.** The window is centred on the first match, so a later one can sit
    /// entirely outside it. Clipping such a match has to skip it rather than
    /// build an inverted range — which trapped, and took the app down in the
    /// middle of a search rather than showing a wrong result.
    func testAMatchOutsideTheWindowIsDropped() {
        let filler = String(repeating: "x", count: 5_000)
        let result = blocks(
            "README" + filler + "README", "README", context: 0
        )
        let text = result.first?.first?.text ?? ""

        XCTAssertTrue(
            text.hasPrefix("README"), "the match the window was built around"
        )
        XCTAssertTrue(text.hasSuffix("…"), "and the rest is elided")
        XCTAssertLessThan(
            text.utf8.count, FileSearchScanner.maxLineBytes + 32
        )
    }

    /// The same shape with the surviving match at the far end, so the window is
    /// built around a late first match and an early one would clip backwards.
    func testMatchesBeforeTheWindowAreDropped() {
        let filler = String(repeating: "x", count: 5_000)
        let result = blocks(
            filler + "README" + filler + "README", "README", context: 0
        )
        let text = result.first?.first?.text ?? ""

        XCTAssertTrue(text.hasPrefix("…"))
        XCTAssertTrue(text.contains("README"))
        XCTAssertLessThan(
            text.utf8.count, FileSearchScanner.maxLineBytes + 32
        )
    }

    /// A context line has no match to centre on, so it shows its head — which
    /// is where a reader looks anyway.
    func testAnEnormousContextLineShowsItsHead() {
        let long = String(repeating: "y", count: 5_000)
        let result = blocks("\(long)\nREADME", "README", context: 1)
        let context = result.first?.first?.text ?? ""

        XCTAssertFalse(context.hasPrefix("…"), "the head is not elided")
        XCTAssertTrue(context.hasSuffix("…"))
        XCTAssertLessThan(
            context.utf8.count, FileSearchScanner.maxLineBytes + 32
        )
    }

    /// A line under the cap is untouched — no window, no ellipsis.
    func testAShortLineIsShownWhole() {
        let result = blocks("a README here", "README", context: 0)
        XCTAssertEqual(result.first?.first?.text, "a README here")
    }

    func testFindsASingleOccurrence() {
        XCTAssertEqual(offsets("hello world", "world").offsets, [6])
    }

    func testFindsEveryOccurrence() {
        XCTAssertEqual(offsets("a-b-a-b-a", "a").offsets, [0, 4, 8])
    }

    func testAMatchAtOffsetZero() {
        XCTAssertEqual(offsets("needle here", "needle").offsets, [0])
    }

    func testAMatchAtTheFinalByte() {
        XCTAssertEqual(offsets("xyz", "z").offsets, [2])
    }

    /// Advancing by the needle's length instead of by one byte would report
    /// one match here, and nobody checks a count they have no reason to doubt.
    func testOverlappingOccurrencesAllCount() {
        XCTAssertEqual(offsets("aaaa", "aa").offsets, [0, 1, 2])
    }

    func testNoMatchIsNoOffsets() {
        XCTAssertEqual(offsets("hello", "zzz").offsets, [])
    }

    func testANeedleLongerThanTheContentFindsNothing() {
        XCTAssertEqual(offsets("ab", "abcdef").offsets, [])
    }

    /// An empty query returning every position would make the results document
    /// the whole corpus.
    func testAnEmptyNeedleFindsNothing() {
        XCTAssertEqual(offsets("anything", "").offsets, [])
    }

    func testCaseSensitiveByRequest() {
        XCTAssertEqual(offsets("Foo foo FOO", "foo").offsets, [4])
    }

    func testCaseInsensitiveFindsEveryCasing() {
        XCTAssertEqual(
            offsets("Foo foo FOO", "foo", caseSensitive: false).offsets,
            [0, 4, 8]
        )
    }

    func testCaseInsensitiveFoldsTheNeedleToo() {
        XCTAssertEqual(
            offsets("foo", "FOO", caseSensitive: false).offsets, [0]
        )
    }

    /// The documented limit of ASCII folding, asserted so it is a known
    /// property rather than a surprise: `É` and `é` are different bytes and
    /// folding them needs a decoder.
    func testNonASCIIIsNotFolded() {
        XCTAssertEqual(
            offsets("Étude", "étude", caseSensitive: false).offsets, []
        )
        XCTAssertEqual(
            offsets("étude", "étude", caseSensitive: false).offsets, [0]
        )
    }

    func testTheLimitStopsAndSaysSo() {
        let result = offsets("aaaaa", "a", limit: 3)
        XCTAssertEqual(result.offsets.count, 3)
        XCTAssertTrue(result.wasTruncated)
    }

    func testFindingEverythingIsNotTruncation() {
        let result = offsets("aaa", "a", limit: 10)
        XCTAssertEqual(result.offsets.count, 3)
        XCTAssertFalse(result.wasTruncated)
    }

    // MARK: - Lines and context

    func testAMatchOnTheFirstLineIsLineOne() {
        let result = blocks("hit\nmiss\n", "hit", context: 0)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].map(\.line), [1])
    }

    func testContextReachesBothWays() {
        let source = "a\nb\nHIT\nd\ne\n"
        let result = blocks(source, "HIT", context: 1)
        XCTAssertEqual(result[0].map(\.line), [2, 3, 4])
    }

    func testContextIsClampedAtTheTop() {
        let result = blocks("HIT\nb\nc\n", "HIT", context: 2)
        XCTAssertEqual(result[0].map(\.line), [1, 2, 3])
    }

    /// Four lines, not three: a trailing newline opens an empty last line, and
    /// `SourceRenderer` renders it — it splits on "\n" and numbers what it
    /// gets. Numbering differently here would put every line number in the
    /// results one off from the reader they link into.
    func testContextIsClampedAtTheBottom() {
        let result = blocks("a\nb\nHIT\n", "HIT", context: 2)
        XCTAssertEqual(result[0].map(\.line), [1, 2, 3, 4])
    }

    func testATrailingNewlineOpensALastLineTheReaderAlsoShows() {
        let source = "a\nb\nHIT\n"
        XCTAssertEqual(
            source.components(separatedBy: "\n").count, 4,
            "the reader's own line count, which this scanner has to match"
        )
        let result = blocks(source, "HIT", context: 9)
        XCTAssertEqual(result[0].map(\.line).last, 4)
    }

    func testZeroContextShowsOnlyMatchingLines() {
        let result = blocks("a\nHIT\nc\nHIT\ne\n", "HIT", context: 0)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].map(\.line), [2])
        XCTAssertEqual(result[1].map(\.line), [4])
    }

    func testDistantMatchesAreSeparateBlocks() {
        let source = "HIT\n" + String(repeating: "x\n", count: 20) + "HIT\n"
        let result = blocks(source, "HIT", context: 2)
        XCTAssertEqual(result.count, 2)
    }

    func testOverlappingWindowsMergeIntoOneBlock() {
        let source = "a\nHIT\nc\nHIT\ne\n"
        let result = blocks(source, "HIT", context: 2)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].map(\.line), [1, 2, 3, 4, 5, 6])
    }

    /// Touching windows merge, so a line is never drawn twice.
    func testAdjacentWindowsMergeWithNoRepeatedLine() {
        // Matches on 1 and 4, context 1 → windows 1–2 and 3–5: no gap.
        let source = "HIT\nb\nc\nHIT\ne\n"
        let result = blocks(source, "HIT", context: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].map(\.line), [1, 2, 3, 4, 5])
    }

    /// A genuine gap stays a gap. Context means the number of lines asked for
    /// and not one more — showing an unrequested line to tidy the output would
    /// make the setting mean something other than what it says.
    func testARealGapStaysTwoBlocks() {
        // Matches on 1 and 5, context 1 → windows 1–2 and 4–6, line 3 unshown.
        let source = "HIT\nb\nc\nd\nHIT\nf\n"
        let result = blocks(source, "HIT", context: 1)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].map(\.line), [1, 2])
        XCTAssertEqual(result[1].map(\.line), [4, 5, 6])
    }

    func testAMatchOnTheLastLineWithNoTrailingNewline() {
        let result = blocks("a\nb\nHIT", "HIT", context: 0)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].map(\.line), [3])
        XCTAssertEqual(result[0][0].text, "HIT")
    }

    func testCRLFLineEndingsDoNotDriftTheOffsets() {
        let result = blocks("a\r\nb\r\nHIT\r\nd\r\n", "HIT", context: 0)
        XCTAssertEqual(result[0].map(\.line), [3])
        XCTAssertEqual(
            result[0][0].text, "HIT",
            "the carriage return is display noise and is dropped"
        )
    }

    // MARK: - Segments

    func testAMatchingLineIsSplitAroundTheHit() {
        let result = blocks("let needle = 1\n", "needle", context: 0)
        XCTAssertEqual(
            result[0][0].segments,
            [
                .init(text: "let ", isMatch: false),
                .init(text: "needle", isMatch: true),
                .init(text: " = 1", isMatch: false),
            ]
        )
    }

    func testAMatchAtTheStartOfALineHasNoLeadingSegment() {
        let result = blocks("needle = 1\n", "needle", context: 0)
        XCTAssertEqual(result[0][0].segments.first?.isMatch, true)
    }

    func testAMatchAtTheEndOfALineHasNoTrailingSegment() {
        let result = blocks("x = needle\n", "needle", context: 0)
        XCTAssertEqual(result[0][0].segments.last?.isMatch, true)
    }

    func testTwoMatchesOnOneLineAreBothMarked() {
        let result = blocks("foo and foo\n", "foo", context: 0)
        let marked = result[0][0].segments.filter(\.isMatch)
        XCTAssertEqual(marked.count, 2)
        XCTAssertEqual(result[0][0].text, "foo and foo")
    }

    /// Overlapping hits on one line must not double the bytes they share.
    func testOverlappingMatchesOnOneLineCoalesce() {
        let result = blocks("aaaa\n", "aa", context: 0)
        XCTAssertEqual(
            result[0][0].text, "aaaa",
            "the line still reads as itself after being split"
        )
        XCTAssertEqual(result[0][0].segments.filter(\.isMatch).count, 1)
    }

    func testAContextLineIsOneUnmatchedSegment() {
        let result = blocks("before\nHIT\n", "HIT", context: 1)
        let context = result[0][0]
        XCTAssertEqual(context.line, 1)
        XCTAssertFalse(context.isMatch)
        XCTAssertEqual(context.segments, [.init(text: "before", isMatch: false)])
    }

    func testAnEmptyContextLineHasNoSegments() {
        let result = blocks("\nHIT\n", "HIT", context: 1)
        XCTAssertEqual(result[0][0].segments, [])
        XCTAssertEqual(result[0][0].text, "")
    }

    func testCaseInsensitiveHighlightsWhatWasActuallyThere() {
        let result = blocks(
            "call FooBar now\n", "foobar", context: 0, caseSensitive: false
        )
        let hit = result[0][0].segments.first { $0.isMatch }
        XCTAssertEqual(
            hit?.text, "FooBar",
            "the file's own casing is shown, not the query's"
        )
    }

    func testNoMatchesProducesNoBlocks() {
        XCTAssertEqual(blocks("nothing here\n", "zzz", context: 2).count, 0)
    }

    func testUnicodeInAMatchingLineSurvivesTheSplit() {
        let result = blocks("héllo needle wörld\n", "needle", context: 0)
        XCTAssertEqual(result[0][0].text, "héllo needle wörld")
    }
}
