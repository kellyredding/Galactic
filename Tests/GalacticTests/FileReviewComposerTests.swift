import XCTest

@testable import Galactic

/// The exact bytes an agent receives.
///
/// This is the file that stops the format drifting. Everything else in the
/// feature has a user watching it — a wrong tab order or a missing badge gets
/// noticed — but the review is read by an agent, and a change here degrades
/// quietly into a message that parses differently or cites the wrong line.
///
/// So these assert whole strings rather than properties of strings. A test that
/// checks "the path appears somewhere" would pass on a format nobody meant.
final class FileReviewComposerTests: XCTestCase {

    private let stamp = "2026-08-17T14:00:00Z"
    private let root = URL(fileURLWithPath: "/work/project")

    private func file(_ path: String, kind: FileKind = .source) -> ReaderFile {
        ReaderFile(
            url: URL(fileURLWithPath: path),
            content: "unused by the composer",
            kind: kind,
            byteSize: 10,
            modifiedAt: Date(timeIntervalSince1970: 0),
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func store(
        _ entries: [(path: String, start: Int32, end: Int32, quote: String, body: String)]
    ) -> FileNoteStore {
        var s = FileNoteStore()
        for e in entries {
            s.add(
                filePath: e.path, startLine: e.start, endLine: e.end,
                lineContent: e.quote, content: e.body, createdAt: stamp
            )
        }
        return s
    }

    private func compose(
        overall: String = "",
        files: [ReaderFile],
        notes: FileNoteStore,
        drifted: Set<String> = []
    ) -> String {
        FileReviewComposer.compose(
            overallComment: overall,
            files: files,
            notes: notes,
            root: root,
            hasDrifted: { drifted.contains($0.url.path) }
        )
    }

    // MARK: - The whole shape

    func testOneNoteIsOneBlock() {
        let out = compose(
            files: [file("/work/project/src/user.rb")],
            notes: store([
                (
                    "/work/project/src/user.rb", 42, 48,
                    "  def activate!\n    return if active?\n  end",
                    "Should this be idempotent?"
                )
            ])
        )

        XCTAssertEqual(
            out,
            """
            [1] src/user.rb:42-48
            ```ruby
              def activate!
                return if active?
              end
            ```
            Should this be idempotent?
            """
        )
    }

    /// The overall comment leads, the way it does on a code review: what the
    /// whole thing is about before the line by line.
    func testTheOverallCommentLeadsAndIsSeparatedByABlankPair() {
        let out = compose(
            overall: "Mostly about the activation path.",
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "x = 1", "why")])
        )

        XCTAssertEqual(
            out,
            "Mostly about the activation path."
                + "\n\n\n"
                + "[1] a.rb:1\n```ruby\nx = 1\n```\nwhy"
        )
    }

    /// Omitted entirely rather than left as a leading blank line.
    func testAnEmptyOverallCommentContributesNothing() {
        let notes = store([("/work/project/a.rb", 1, 1, "x = 1", "why")])

        XCTAssertEqual(
            compose(overall: "", files: [file("/work/project/a.rb")], notes: notes),
            compose(overall: "   \n  ", files: [file("/work/project/a.rb")], notes: notes),
            "whitespace is the same as absent"
        )
        XCTAssertTrue(
            compose(overall: "", files: [file("/work/project/a.rb")], notes: notes)
                .hasPrefix("[1]")
        )
    }

    func testNoTrailingNewlineAndNoPreamble() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "x = 1", "why")])
        )

        XCTAssertFalse(out.hasSuffix("\n"))
        XCTAssertTrue(
            out.hasPrefix("[1]"),
            "the reader's own words are the only prose in the message"
        )
    }

    func testNothingToSayIsAnEmptyMessage() {
        XCTAssertEqual(
            compose(files: [file("/work/project/a.rb")], notes: FileNoteStore()),
            ""
        )
        XCTAssertEqual(
            compose(overall: "a comment with no notes",
                    files: [file("/work/project/a.rb")],
                    notes: FileNoteStore()),
            "",
            "a comment alone is not a review"
        )
    }

    // MARK: - Numbering and order

    /// Positional across the whole review, so "on 2" is unambiguous. The notes'
    /// own numbers here are 1 and 1 — one per file — and neither ships.
    func testNumberingRunsAcrossFilesRatherThanWithinThem() {
        let out = compose(
            files: [file("/work/project/a.rb"), file("/work/project/b.rb")],
            notes: store([
                ("/work/project/a.rb", 1, 1, "a", "first"),
                ("/work/project/b.rb", 1, 1, "b", "second"),
            ])
        )

        XCTAssertTrue(out.contains("[1] a.rb:1"))
        XCTAssertTrue(out.contains("[2] b.rb:1"))
    }

    /// Files in tab order, not alphabetical and not by when notes were written.
    func testFilesFollowTabOrder() {
        let notes = store([
            ("/work/project/z.rb", 1, 1, "z", "on z"),
            ("/work/project/a.rb", 1, 1, "a", "on a"),
        ])

        let zFirst = compose(
            files: [file("/work/project/z.rb"), file("/work/project/a.rb")],
            notes: notes
        )
        let aFirst = compose(
            files: [file("/work/project/a.rb"), file("/work/project/z.rb")],
            notes: notes
        )

        XCTAssertTrue(zFirst.hasPrefix("[1] z.rb:1"))
        XCTAssertTrue(aFirst.hasPrefix("[1] a.rb:1"))
    }

    func testNotesWithinAFileFollowDocumentOrder() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([
                ("/work/project/a.rb", 40, 48, "later", "third"),
                ("/work/project/a.rb", 2, 2, "early", "first"),
                ("/work/project/a.rb", 10, 12, "middle", "second"),
            ])
        )

        XCTAssertTrue(out.contains("[1] a.rb:2\n"))
        XCTAssertTrue(out.contains("[2] a.rb:10-12\n"))
        XCTAssertTrue(out.contains("[3] a.rb:40-48\n"))
    }

    /// A caller passes its whole strip rather than filtering, so a file with no
    /// notes has to fall out here without consuming a number.
    func testAFileWithNoNotesIsSkippedWithoutTakingANumber()  {
        let out = compose(
            files: [
                file("/work/project/untouched.rb"),
                file("/work/project/annotated.rb"),
            ],
            notes: store([("/work/project/annotated.rb", 5, 5, "q", "why")])
        )

        XCTAssertEqual(out, "[1] annotated.rb:5\n```ruby\nq\n```\nwhy")
    }

    func testBlocksAreSeparatedByExactlyTwoBlankLines() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([
                ("/work/project/a.rb", 1, 1, "one", "first"),
                ("/work/project/a.rb", 2, 2, "two", "second"),
            ])
        )

        XCTAssertEqual(
            out,
            "[1] a.rb:1\n```ruby\none\n```\nfirst"
                + "\n\n\n"
                + "[2] a.rb:2\n```ruby\ntwo\n```\nsecond"
        )
    }

    // MARK: - Locations

    func testASingleLineHasNoRange() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 7, 7, "q", "why")])
        )

        XCTAssertTrue(out.hasPrefix("[1] a.rb:7\n"))
    }

    /// A set may hold files from anywhere, which is what lets a reader open
    /// source beside guidelines from another tree. Shortening applies where it
    /// can and is never a claim about where a file lives.
    func testAFileOutsideTheRootKeepsItsAbsolutePath() {
        let out = compose(
            files: [file("/elsewhere/notes.md")],
            notes: store([("/elsewhere/notes.md", 3, 3, "q", "why")])
        )

        XCTAssertTrue(out.hasPrefix("[1] /elsewhere/notes.md:3\n"))
    }

    /// A sibling directory whose name merely starts with the root's must not be
    /// mistaken for being inside it.
    func testAPathSharingAPrefixWithTheRootIsNotShortened() {
        XCTAssertEqual(
            FileReviewComposer.displayPath(
                for: URL(fileURLWithPath: "/work/project-other/a.rb"),
                root: root
            ),
            "/work/project-other/a.rb"
        )
    }

    func testARootWithATrailingSlashShortensTheSame() {
        XCTAssertEqual(
            FileReviewComposer.displayPath(
                for: URL(fileURLWithPath: "/work/project/src/a.rb"),
                root: URL(fileURLWithPath: "/work/project/")
            ),
            "src/a.rb"
        )
    }

    // MARK: - Drift

    func testADriftedFileIsMarkedOnEveryOneOfItsBlocks() {
        let out = compose(
            files: [file("/work/project/a.rb"), file("/work/project/b.rb")],
            notes: store([
                ("/work/project/a.rb", 1, 1, "one", "first"),
                ("/work/project/a.rb", 2, 2, "two", "second"),
                ("/work/project/b.rb", 1, 1, "b", "on b"),
            ]),
            drifted: ["/work/project/a.rb"]
        )

        XCTAssertTrue(
            out.contains("[1] a.rb:1 \(FileReviewComposer.driftMarker)")
        )
        XCTAssertTrue(
            out.contains("[2] a.rb:2 \(FileReviewComposer.driftMarker)")
        )
        XCTAssertFalse(
            out.contains("b.rb:1 \(FileReviewComposer.driftMarker)"),
            "the file that did not move is not marked"
        )
    }

    /// One stat per file, not one per note — the answer cannot differ between
    /// two notes on the same file, and each ask touches the filesystem.
    func testDriftIsAskedOncePerFile() {
        var asked: [String] = []
        _ = FileReviewComposer.compose(
            overallComment: "",
            files: [file("/work/project/a.rb")],
            notes: store([
                ("/work/project/a.rb", 1, 1, "one", "first"),
                ("/work/project/a.rb", 2, 2, "two", "second"),
                ("/work/project/a.rb", 3, 3, "three", "third"),
            ]),
            root: root,
            hasDrifted: { asked.append($0.url.path); return false }
        )

        XCTAssertEqual(asked.count, 1)
    }

    /// Not asked at all for a file carrying no notes, since nothing about it
    /// reaches the message.
    func testDriftIsNotAskedForAFileWithNoNotes() {
        var asked = 0
        _ = FileReviewComposer.compose(
            overallComment: "",
            files: [file("/work/project/untouched.rb")],
            notes: FileNoteStore(),
            root: root,
            hasDrifted: { _ in asked += 1; return false }
        )

        XCTAssertEqual(asked, 0)
    }

    // MARK: - Language tags

    func testTheFenceCarriesTheFilesLanguage() {
        let out = compose(
            files: [file("/work/project/main.swift")],
            notes: store([("/work/project/main.swift", 1, 1, "let x = 1", "why")])
        )

        XCTAssertTrue(out.contains("```swift\n"))
    }

    /// The vendored highlighter ships a subset, so plenty of readable files
    /// have no language. A bare fence is the honest answer.
    func testAFileWithNoKnownLanguageGetsABareFence() {
        let out = compose(
            files: [file("/work/project/infra.tf")],
            notes: store([("/work/project/infra.tf", 1, 1, "resource {}", "why")])
        )

        XCTAssertTrue(out.contains("```\nresource {}\n```"))
    }

    /// An extensionless build file still names its language, which is the
    /// whole-name lookup earning its place in the review rather than only on
    /// screen.
    func testAnExtensionlessFileStillNamesItsLanguage() {
        let out = compose(
            files: [file("/work/project/Makefile")],
            notes: store([("/work/project/Makefile", 1, 1, "all:", "why")])
        )

        XCTAssertTrue(out.contains("```makefile\n"))
    }

    // MARK: - Content is quoted verbatim

    /// A quote containing a fence is left alone. Escaping it would corrupt the
    /// thing being asked about, and an agent reading a nested fence loses less
    /// than one reading altered source.
    func testAQuoteContainingAFenceIsNotEscaped() {
        let out = compose(
            files: [file("/work/project/README.md")],
            notes: store([
                ("/work/project/README.md", 1, 2, "```\ncode\n```", "meta")
            ])
        )

        XCTAssertTrue(out.contains("```\n```\ncode\n```\n```"))
    }

    func testMultiLineNoteTextSurvivesUnchanged() {
        let body = "First thought.\n\nSecond thought."
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "q", body)])
        )

        XCTAssertTrue(out.hasSuffix(body))
    }
}
