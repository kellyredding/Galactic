import XCTest

@testable import Galactic

/// What the picker offers, and in what order.
///
/// Two of these assertions are the bugs this replaced: a query containing a
/// space matched nothing at all, and the ranking sorted a quarter of a million
/// results to show a hundred. The rest guard the optimisations — a prefilter
/// and a bounded selection are only allowed to be faster, never different.
final class FileMatcherTests: XCTestCase {

    private let root = "/tmp/matcher-root"

    private func corpus(_ paths: [String], modified: [String: Date] = [:])
        -> FileCorpus
    {
        var writer = FileCorpusWriter()
        for path in paths {
            writer.add(
                relativePath: path, modified: modified[path], isDirectory: false
            )
        }
        return writer.finish(root: root)
    }

    private func ranked(
        _ paths: [String], _ query: String, limit: Int = 100,
        modified: [String: Date] = [:]
    ) -> [String] {
        let built = corpus(paths, modified: modified)
        return FileMatcher.matches(in: built, query: query, limit: limit)
            .map { built.relativePath(at: $0.index) }
    }

    // MARK: - The bug that made spaced queries match nothing

    /// Nobody types a whole path. They type remembered fragments in the order
    /// they remember them, and the space between them means "then, later".
    func testWhitespaceIsAGapNotACharacterToFind() {
        let found = ranked(
            ["projects/kelly/readme.md", "other/file.txt"], "projects kelly readme"
        )
        XCTAssertEqual(found, ["projects/kelly/readme.md"])
    }

    /// And the converse: a path that genuinely contains a space is still
    /// reachable, because the space in the *path* is one of the gaps.
    func testSpaceInThePathIsSkippedLikeAnyOtherGap() {
        XCTAssertEqual(
            ranked(["Desktop/AI prompts.txt"], "ai prompts"),
            ["Desktop/AI prompts.txt"]
        )
    }

    func testFragmentsMustBeInOrder() {
        XCTAssertTrue(ranked(["projects/galaxy/file.swift"], "galaxy projects").isEmpty)
    }

    /// A space used to be deleted, which cost the runs either side their
    /// contiguity and the whole match its basename bonus. Measured before
    /// tokens, `linear cli` scored this path 126 and left a path merely
    /// scattering the letters on top of it.
    func testASpacedQueryRanksTheJoinedNameFirst() {
        let wanted = "projects/kajabi/agent-guidelines/linear-cli.md"
        let found = ranked(
            [wanted, "projects/kajabi/linear-agent/.claude/plugins/red-green.md"],
            "linear cli"
        )
        XCTAssertEqual(found.first, wanted)
    }

    /// What the space costs is now only the separator the reader did not type:
    /// its own match award, and the contiguity either side of it. Nothing
    /// structural — no gap charge, no forfeited basename bonus. Stated against
    /// the weights rather than a literal so a reweighting cannot make this
    /// silently vacuous.
    func testASpacedQueryLosesOnlyTheSeparatorItDidNotType() {
        let path = "projects/kajabi/agent-guidelines/linear-cli.md"
        XCTAssertEqual(
            score(path, "linear-cli") - score(path, "linear cli"),
            FileMatchAlignment.matchScore + 2 * FileMatchAlignment.contiguousBonus
        )
    }

    func testEachTokenEarnsItsOwnWordStart() {
        let found = ranked(
            ["src/file/picker.swift", "src/affix/perks.swift"], "file picker"
        )
        XCTAssertEqual(found.first, "src/file/picker.swift")
    }

    // MARK: - Smart case

    func testLowercaseQueryIsCaseInsensitive() {
        XCTAssertEqual(ranked(["src/README.md"], "readme"), ["src/README.md"])
    }

    func testUppercaseInTheQueryMakesItCaseSensitive() {
        let paths = ["src/README.md", "src/readme.md"]
        XCTAssertEqual(ranked(paths, "README"), ["src/README.md"])
    }

    // MARK: - Diacritics, under the same rule as case

    /// Stated by the person who asked for it: type `cafe`, find `café`.
    func testPlainQueryMatchesAnAccentedPath() {
        XCTAssertEqual(ranked(["notes/café.md"], "cafe"), ["notes/café.md"])
    }

    func testAccentedQueryDoesNotMatchThePlainPath() {
        let found = ranked(["notes/cafe.md", "notes/café.md"], "café")
        XCTAssertEqual(found, ["notes/café.md"])
    }

    // MARK: - Ordering

    func testWordStartsOutrankLettersBuriedMidWord() {
        let found = ranked(["src/file_picker.swift", "misc/affixperks.swift"], "fp")
        XCTAssertEqual(found.first, "src/file_picker.swift")
    }

    /// The measured defect: first-fit spent `l`, `i`, `n`, `e` on the
    /// directories and reached the filename with only `ar-cli` left to place,
    /// so the row holding the query as a literal substring lost to one that
    /// merely scattered it.
    func testALiteralSubstringInTheFilenameOutranksAScatteredMatch() {
        let wanted = "projects/kajabi/kajabi-files/agent-guidelines/linear-cli.md"
        let found = ranked(
            [wanted, "projects/kajabi/linear-agent/.claude/plugins/red-green.md"],
            "linear-cli"
        )
        XCTAssertEqual(found.first, wanted)
    }

    /// The same filename must not score wildly differently because of what
    /// sits above it. Measured before this change: 246 against 153.
    ///
    /// Not equality — the leading penalty legitimately differs. The claim is
    /// that the gap is bounded by that penalty rather than by a forfeited
    /// basename bonus and four lost contiguity awards.
    func testParentDirectoriesDoNotChangeAFilenamesScore() {
        let short = score("agent/linear-cli.md", "linear-cli")
        let long = score(
            "projects/kajabi/kajabi-files/agent-guidelines/linear-cli.md",
            "linear-cli"
        )
        XCTAssertGreaterThan(long, short - 40)
    }

    /// A contiguous run must be found even when a scattered alignment
    /// completes earlier in the path — the case the backward pass alone cannot
    /// reach, and the reason the contiguous-occurrence pass exists.
    func testAContiguousRunIsPreferredToAnEarlierScatteredOne() {
        let found = ranked(["l/i/n/e/notes-line.md", "docs/line.md"], "line")
        XCTAssertEqual(found.first, "docs/line.md")
    }

    /// The bonus says the match is in the file's own name. It used to compare
    /// against the last separator *seen before the match ended*, so `docs`
    /// matching the directory in `docs/notes.md` collected it.
    func testMatchingADirectoryDoesNotEarnTheBasenameBonus() {
        let found = ranked(["docs/notes.md", "notes/docs.md"], "docs")
        XCTAssertEqual(found.first, "notes/docs.md")
    }

    func testShorterPathWinsAtEqualScore() {
        let found = ranked(["a/readme.md", "a/b/c/readme.md"], "readme")
        XCTAssertEqual(found.first, "a/readme.md")
    }

    /// Recency breaks ties. It must not overturn a better name match, which is
    /// why the bonus is small next to what a well-placed character earns.
    func testRecentFileOutranksAnIdenticalOlderOne() {
        let now = Date()
        let old = Date(timeIntervalSinceNow: -365 * 86_400)
        let found = ranked(
            ["one/notes.md", "two/notes.md"], "notes",
            modified: ["two/notes.md": now, "one/notes.md": old]
        )
        XCTAssertEqual(found.first, "two/notes.md")
    }

    func testRecencyDoesNotOverturnAClearlyBetterMatch() {
        let now = Date()
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let found = ranked(
            ["notes.md", "n/o/t/e/s/unrelated.md"], "notes",
            modified: ["n/o/t/e/s/unrelated.md": now, "notes.md": old]
        )
        XCTAssertEqual(found.first, "notes.md")
    }

    // MARK: - The optimisations must not change the answer

    /// A prefilter is allowed to be faster and nothing else. This walks the
    /// same corpus with a naive subsequence test and demands the same set.
    func testPrefilterAndScanAgreeWithANaiveSubsequence() {
        var paths: [String] = []
        for outer in 0..<60 {
            for inner in 0..<60 {
                paths.append("pkg\(outer)/module\(inner)/user_model.rb")
                paths.append("pkg\(outer)/module\(inner)/README.md")
            }
        }
        let built = corpus(paths)

        for query in ["usermodel", "rme", "pkg7mod", "zzz", "md"] {
            let matched = Set(
                FileMatcher.matches(in: built, query: query, limit: .max)
                    .map { built.relativePath(at: $0.index) }
            )
            let expected = Set(paths.filter { isSubsequence(query, of: $0) })
            XCTAssertEqual(
                matched, expected, "prefilter disagreed for query \(query)"
            )
        }
    }

    /// Bounded selection must equal the head of a full sort — that is the
    /// whole claim being made by not sorting the rest.
    func testBoundedSelectionEqualsTheHeadOfAFullSort() {
        var paths: [String] = []
        for index in 0..<5_000 { paths.append("dir\(index % 40)/file\(index).swift") }
        let built = corpus(paths)

        let everything = FileMatcher.matches(in: built, query: "file", limit: .max)
        let topTen = FileMatcher.matches(in: built, query: "file", limit: 10)
        XCTAssertEqual(topTen.count, 10)
        XCTAssertEqual(
            topTen.map(\.index), Array(everything.prefix(10).map(\.index))
        )
    }

    /// The corpus is scanned in parallel above a threshold, and a chunk
    /// boundary that split an entry would show up here as a missing match.
    func testParallelAndSerialScansAgree() {
        var paths: [String] = []
        for index in 0..<40_000 { paths.append("pkg\(index % 500)/file\(index).swift") }
        let built = corpus(paths)
        XCTAssertGreaterThan(built.entryCount, 20_000, "must exceed the parallel threshold")

        let parallel = FileMatcher.matches(in: built, query: "pkg42file", limit: 50)
        let serial = FileMatcher.matches(
            in: built, range: 0..<built.entryCount, query: "pkg42file", limit: 50
        )
        XCTAssertFalse(parallel.isEmpty)
        XCTAssertEqual(parallel.map(\.index), serial.map(\.index))
    }

    func testCancellationReturnsNothingRatherThanAPartialAnswer() {
        let built = corpus((0..<1_000).map { "dir/file\($0).swift" })
        let cancellation = FileMatcher.Cancellation()
        cancellation.cancel()
        XCTAssertTrue(
            FileMatcher.matches(
                in: built, query: "file", limit: 10, cancellation: cancellation
            ).isEmpty
        )
    }

    func testSearchingASubtreeOnlySeesThatSubtree() {
        let built = corpus(["apps/one.swift", "docs/one.swift"])
        let range = built.range(under: root + "/apps")
        let found = FileMatcher.matches(
            in: built, range: range, query: "one", limit: 10
        )
        XCTAssertEqual(found.map { built.relativePath(at: $0.index) }, ["apps/one.swift"])
    }

    // MARK: - Directories are indexed but not offered

    /// The corpus holds directories so re-rooting and path completion can be
    /// answered from memory. A picker that opens files into a reader has no
    /// use for a directory row, and offering one is worse than useless: it is
    /// shorter than the files beneath it, so it outranks them.
    func testDirectoriesAreNotOfferedAsResults() {
        var writer = FileCorpusWriter()
        writer.add(relativePath: "src", modified: nil, isDirectory: true)
        writer.add(relativePath: "src/main.swift", modified: nil, isDirectory: false)
        let built = writer.finish(root: root)

        let found = FileMatcher.matches(in: built, query: "src", limit: 10)
        XCTAssertEqual(found.map { built.relativePath(at: $0.index) }, ["src/main.swift"])
    }

    func testDirectoriesAreOfferedWhenAskedFor() {
        var writer = FileCorpusWriter()
        writer.add(relativePath: "src", modified: nil, isDirectory: true)
        writer.add(relativePath: "src/main.swift", modified: nil, isDirectory: false)
        let built = writer.finish(root: root)

        let found = FileMatcher.matches(
            in: built, query: "src", limit: 10, includingDirectories: true
        )
        XCTAssertEqual(
            Set(found.map { built.relativePath(at: $0.index) }),
            ["src", "src/main.swift"]
        )
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(FileMatcher.matches(in: corpus(["a.txt"]), query: "  ", limit: 10).isEmpty)
    }

    /// One path's score, for assertions about magnitude rather than order.
    private func score(_ path: String, _ query: String) -> Int {
        let built = corpus([path])
        return FileMatcher.matches(in: built, query: query, limit: 1)
            .first?.score ?? Int.min
    }

    private func isSubsequence(_ needle: String, of candidate: String) -> Bool {
        var remaining = Array(needle.lowercased())
        for character in candidate.lowercased() where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
