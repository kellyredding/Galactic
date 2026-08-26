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
final class AgentReviewComposerTests: XCTestCase {

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
        AgentReviewComposer.compose(
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
            >   def activate!
            >     return if active?
            >   end
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
                + "[1] a.rb:1\n> x = 1\nwhy"
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

        XCTAssertEqual(out, "[1] annotated.rb:5\n> q\nwhy")
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
            "[1] a.rb:1\n> one\nfirst"
                + "\n\n\n"
                + "[2] a.rb:2\n> two\nsecond"
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
            AgentReviewComposer.displayPath(
                for: URL(fileURLWithPath: "/work/project-other/a.rb"),
                root: root
            ),
            "/work/project-other/a.rb"
        )
    }

    func testARootWithATrailingSlashShortensTheSame() {
        XCTAssertEqual(
            AgentReviewComposer.displayPath(
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
            out.contains("[1] a.rb:1 \(AgentReviewComposer.driftMarker)")
        )
        XCTAssertTrue(
            out.contains("[2] a.rb:2 \(AgentReviewComposer.driftMarker)")
        )
        XCTAssertFalse(
            out.contains("b.rb:1 \(AgentReviewComposer.driftMarker)"),
            "the file that did not move is not marked"
        )
    }

    /// One stat per file, not one per note — the answer cannot differ between
    /// two notes on the same file, and each ask touches the filesystem.
    func testDriftIsAskedOncePerFile() {
        var asked: [String] = []
        _ = AgentReviewComposer.compose(
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
        _ = AgentReviewComposer.compose(
            overallComment: "",
            files: [file("/work/project/untouched.rb")],
            notes: FileNoteStore(),
            root: root,
            hasDrifted: { _ in asked += 1; return false }
        )

        XCTAssertEqual(asked, 0)
    }

    // MARK: - How the quote is marked

    /// Every line, not two ends. This is the property that makes the delimiter
    /// unbreakable by its own content.
    func testEveryQuotedLineCarriesThePrefix() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 3, "one\ntwo\nthree", "why")])
        )

        XCTAssertTrue(out.contains("> one\n> two\n> three\nwhy"))
    }

    /// Nothing reinterprets what follows the prefix, so indentation arrives as
    /// it was captured — which is most of what a code quote is for.
    func testLeadingWhitespaceSurvivesExactly() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([
                ("/work/project/a.rb", 1, 2, "    deep\n\t\ttabbed", "why")
            ])
        )

        XCTAssertTrue(out.contains(">     deep\n> \t\ttabbed"))
    }

    /// A blank line inside a quote is marked without gaining trailing
    /// whitespace, which a bare `> ` would add to every empty line.
    func testABlankQuotedLineIsABareMarker() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 3, "one\n\nthree", "why")])
        )

        XCTAssertTrue(out.contains("> one\n>\n> three"))
        XCTAssertFalse(out.contains("> \n"))
    }

    /// A capture that ends in a newline must not produce a final marker for a
    /// line it does not have.
    func testATrailingNewlineDoesNotBecomeAnEmptyQuotedLine() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "one\n", "why")])
        )

        XCTAssertTrue(out.hasSuffix("> one\nwhy"))
    }

    /// The note is bare, and that asymmetry is the delimiter: no label, nothing
    /// to match, and no way to confuse the reader's prose with the file's.
    func testTheNoteItselfIsNotMarked() {
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "q", "my own words")])
        )

        XCTAssertTrue(out.hasSuffix("\nmy own words"))
    }

    // MARK: - Content is quoted verbatim

    /// The case the old format could not survive, and the reason for this one.
    ///
    /// A fenced quote containing a fence ended early, and everything after it
    /// arrived as prose between the quote and the note — most likely on exactly
    /// the files a reader annotates most, since markdown is full of fences. The
    /// choice used to be between corrupting the source by escaping it and
    /// handing an agent an ambiguous block. A prefix costs neither.
    func testAQuoteContainingAFenceStaysWhollyQuoted() {
        let out = compose(
            files: [file("/work/project/README.md")],
            notes: store([
                ("/work/project/README.md", 1, 3, "```\ncode\n```", "meta")
            ])
        )

        XCTAssertTrue(out.contains("> ```\n> code\n> ```\nmeta"))
    }

    /// A quoted line that already begins with a marker simply gains another. It
    /// still cannot be mistaken for the note, which has none.
    func testAQuotedLineAlreadyBeginningWithAMarkerGainsAnother() {
        let out = compose(
            files: [file("/work/project/a.md")],
            notes: store([("/work/project/a.md", 1, 1, "> quoted", "meta")])
        )

        XCTAssertTrue(out.contains("> > quoted\nmeta"))
    }

    func testMultiLineNoteTextSurvivesUnchanged() {
        let body = "First thought.\n\nSecond thought."
        let out = compose(
            files: [file("/work/project/a.rb")],
            notes: store([("/work/project/a.rb", 1, 1, "q", body)])
        )

        XCTAssertTrue(out.hasSuffix(body))
    }

    // MARK: - One serialiser for both kinds of note
    //
    // The quoting rule, the numbering and the separator were written twice —
    // here in Swift, and again as JavaScript inside the scrollback renderer,
    // with a comment claiming the two were byte-identical and nothing checking
    // it. The page no longer composes: it posts its notes and they come through
    // this. These assert the part that made two implementations tempting — that
    // the two shapes differ in one thing — so the difference stays a nil rather
    // than becoming a second format again.

    /// A scrollback note has nowhere to point, and says so by saying nothing.
    func testANoteWithNoLocationShipsThePositionAlone() {
        let out = AgentReviewComposer.compose(
            overallComment: "",
            notes: [
                .init(location: nil, lineContent: "a\nb", content: "why")
            ]
        )

        XCTAssertEqual(out, "[1]\n> a\n> b\nwhy")
    }

    /// A file note is the same block with a location on the header line.
    func testALocationOnlyChangesTheHeaderLine() {
        let bare = AgentReviewComposer.compose(
            overallComment: "",
            notes: [
                .init(location: nil, lineContent: "a\nb", content: "why")
            ]
        )
        let located = AgentReviewComposer.compose(
            overallComment: "",
            notes: [
                .init(
                    location: "src/a.swift:3-4",
                    lineContent: "a\nb",
                    content: "why"
                )
            ]
        )

        // Everything after the first line is identical — the quoting, the
        // blank-line handling and the note's own prose do not know or care
        // which surface the note came from.
        XCTAssertEqual(
            bare.split(separator: "\n", maxSplits: 1).last,
            located.split(separator: "\n", maxSplits: 1).last
        )
        XCTAssertTrue(located.hasPrefix("[1] src/a.swift:3-4\n"))
    }

    /// The comment leads both kinds, over the same separator.
    func testTheCommentLeadsWhicheverKindItIs() {
        let notes: [AgentReviewComposer.ReviewNote] = [
            .init(location: nil, lineContent: "x", content: "n1"),
            .init(location: "a.swift:1", lineContent: "y", content: "n2"),
        ]
        let out = AgentReviewComposer.compose(
            overallComment: "  the summary  ", notes: notes
        )

        XCTAssertEqual(
            out,
            "the summary"
                + AgentReviewComposer.blockSeparator
                + "[1]\n> x\nn1"
                + AgentReviewComposer.blockSeparator
                + "[2] a.swift:1\n> y\nn2"
        )
    }

    // MARK: - The lead, shared with reviews this does not compose
    //
    // Artifact and snapshot reviews hand the agent commands rather than a
    // transcript, so their bodies are their own — but the summary above them is
    // this convention, and each spelling it for itself is what let all three
    // drift apart. These pin the two ways they differed.

    /// A summary a reader only tabbed through is not a summary.
    func testAWhitespaceOnlyCommentLeadsNothing() {
        XCTAssertEqual(AgentReviewComposer.leading("   \n\t "), "")
        XCTAssertEqual(AgentReviewComposer.leading(""), "")
    }

    /// The gap under the comment is the wide one — never narrower than the gaps
    /// between the blocks beneath it, which would read as though the summary
    /// belonged to the first block rather than to the whole review.
    func testTheLeadUsesTheBlockSeparator() {
        XCTAssertEqual(
            AgentReviewComposer.leading("  the summary  "),
            "the summary" + AgentReviewComposer.blockSeparator
        )
    }

    /// And what `compose` puts above a body is the same thing, so a review with
    /// notes and a review that only points at them agree.
    func testComposeLeadsWithTheSharedRule() {
        let out = AgentReviewComposer.compose(
            overallComment: " summary ",
            notes: [.init(location: nil, lineContent: "x", content: "n")]
        )

        XCTAssertTrue(out.hasPrefix(AgentReviewComposer.leading(" summary ")))
    }

    /// Numbering runs across the whole review, not per surface or per file.
    func testPositionsRunAcrossTheWholeReview() {
        let out = AgentReviewComposer.compose(
            overallComment: "",
            notes: (1...3).map {
                .init(location: nil, lineContent: "l", content: "n\($0)")
            }
        )

        XCTAssertTrue(out.contains("[1]"))
        XCTAssertTrue(out.contains("[2]"))
        XCTAssertTrue(out.contains("[3]"))
    }
}
