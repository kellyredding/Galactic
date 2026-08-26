import Foundation

/// Turns a review's notes into the one message an agent receives.
///
/// **The one serialiser for a review, whatever surface it came from.** A file
/// note and a scrollback note arrive by different routes and leave in the same
/// shape, because the quoting, the numbering, the separator and the leading
/// comment are decided once — here. Named for its audience rather than its
/// source for that reason: nothing about it is about files.
///
/// Composed in Swift on both paths. The scrollback used to build its message
/// inside the page, in a JavaScript copy of these rules carrying a comment that
/// claimed byte-identity with them and nothing that checked it. It now posts
/// its notes as data and comes through here.
///
/// **Self-contained**, unlike an artifact review: it quotes what it is about
/// rather than handing the agent commands to fetch it. There is nothing to
/// fetch, because nothing was stored — which is the difference in kind that
/// keeps the two from being one composer.
public enum AgentReviewComposer {

    /// Appended to a location when the file no longer matches what was read.
    ///
    /// Says only that it moved, never how. A reader who wants the difference
    /// has the file; what this has to communicate is that the quote below is
    /// the ground truth and the line number above it may not be.
    static let driftMarker = "(file changed since it was read)"

    /// Between blocks, and after the overall comment. Byte-identical to the
    /// scrollback's separator, because an agent reading both should not have to
    /// learn two shapes.
    static let blockSeparator = "\n\n\n"

    /// - Parameters:
    ///   - overallComment: what the whole review is about. Leads, the way it
    ///     does on a code review — the shape of the thing before the line by
    ///     line. Omitted entirely when empty rather than left as a blank line.
    ///   - files: every open file, **in tab order**. Files with no notes are
    ///     skipped, so a caller passes its whole strip rather than filtering.
    ///   - notes: the set's store.
    ///   - root: the browsing root, for deciding which paths shorten.
    ///   - hasDrifted: injected so this is testable without a filesystem, and
    ///     so the stat happens once per file rather than once per note.
    /// One note as the agent sees it, wherever it was written.
    ///
    /// A file note and a scrollback note differ in exactly one thing — whether
    /// there is a location to name, since terminal output is not a file — so
    /// they travel as the same value and are serialised by the same code.
    public struct ReviewNote: Equatable {
        /// `path:range`, already shortened, or nil when there is nowhere to
        /// point. Nil emits the position alone.
        public let location: String?
        public let lineContent: String
        public let content: String

        public init(location: String?, lineContent: String, content: String) {
            self.location = location
            self.lineContent = lineContent
            self.content = content
        }
    }

    /// **The one serialiser for a review, from any surface.**
    ///
    /// Both kinds of note used to be turned into text twice — this file for a
    /// file review, and a JavaScript copy inside the scrollback renderer for a
    /// scrollback one, whose comment claimed byte-identity with this and had
    /// nothing enforcing it. Two implementations of one format stay identical
    /// exactly as long as someone remembers, which is not a property worth
    /// relying on for the thing an agent reads.
    public static func compose(
        overallComment: String,
        notes: [ReviewNote]
    ) -> String {
        guard !notes.isEmpty else { return "" }

        // Positional across the whole review, 1…N, so a reply saying "on 2" is
        // unambiguous. A note's own number is per file and never ships.
        let blocks = notes.enumerated().map { index, note in
            block(position: index + 1, note: note)
        }

        return leading(overallComment) + blocks.joined(
            separator: blockSeparator
        )
    }

    /// A summary comment ready to lead a message, or nothing at all.
    ///
    /// **Shared with the reviews this type does not compose.** An artifact or a
    /// snapshot review hands the agent commands rather than a transcript, so its
    /// body is entirely its own — but the comment above it is the same
    /// convention, and someone typing one should not get a different shape
    /// depending on which surface they typed it into. Those two spelled it for
    /// themselves and had already drifted from this in both directions.
    ///
    /// **The gap is the wide one, and that is not arbitrary.** Blocks are
    /// separated by it because a block is multi-line and its prose may contain
    /// blank lines of its own. The comment is a larger break than any boundary
    /// below it, so separating it by less would read as though it belonged to
    /// the first block rather than to the whole review.
    ///
    /// **Whitespace-only is nothing.** A field someone tabbed through is not a
    /// summary, and shipping one puts an empty line above the review while
    /// telling the agent a comment was written.
    public static func leading(_ comment: String) -> String {
        let trimmed = comment.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? "" : trimmed + blockSeparator
    }

    public static func compose(
        overallComment: String,
        files: [ReaderFile],
        notes: FileNoteStore,
        root: URL,
        hasDrifted: (ReaderFile) -> Bool = FileDriftCheck.hasDrifted
    ) -> String {
        var reviewNotes: [ReviewNote] = []

        for file in files {
            let path = file.url.path
            let fileNotes = notes.notes(forPath: path)
            guard !fileNotes.isEmpty else { continue }

            // Once per file, not once per note: the answer cannot differ
            // between two notes on the same file, and each ask is a stat.
            let drifted = hasDrifted(file)
            let shown = displayPath(for: file.url, root: root)

            for note in fileNotes {
                let range =
                    note.startLine == note.endLine
                    ? "\(note.startLine)"
                    : "\(note.startLine)-\(note.endLine)"
                var location = "\(shown):\(range)"
                if drifted { location += " \(driftMarker)" }
                reviewNotes.append(
                    ReviewNote(
                        location: location,
                        lineContent: note.lineContent,
                        content: note.content
                    )
                )
            }
        }

        return compose(overallComment: overallComment, notes: reviewNotes)
    }

    /// One note, as the agent sees it.
    ///
    /// Every block carries its own path even though blocks are grouped by file.
    /// Grouping is ordering, not a header — a block quoted back in isolation,
    /// or read after the agent has scrolled, still has to say where it came
    /// from.
    private static func block(position: Int, note: ReviewNote) -> String {
        // The position always ships; the location only when there is one.
        // Terminal output has nowhere to point, and a scrollback block that
        // said `[1] :` would be naming an absence.
        let header =
            note.location.map { "[\(position)] \($0)" } ?? "[\(position)]"

        return header + "\n"
            + quoted(note.lineContent) + "\n"
            + note.content
    }

    /// The captured lines, marked as quoted on every line.
    ///
    /// A fence marks two ends; this marks every line, and that difference is the
    /// whole reason for it. **A fence can be closed by its own content** — a
    /// quoted markdown file, a README, a docstring discussing shell commands —
    /// and when it is, the block ends early and the remainder of the snippet
    /// arrives as loose prose between the quote and the note. Nothing reports it.
    /// The earlier format accepted that on the argument that a nested fence costs
    /// an agent less than altered source would; a prefix costs neither.
    ///
    /// There is no rendering step anywhere in this path — the string goes into a
    /// prompt — so this is chosen for a reader that reads raw text. Leading
    /// whitespace survives exactly, since nothing reinterprets what follows the
    /// prefix, and a quoted line already beginning with `>` simply gains
    /// another.
    ///
    /// The note itself is left bare, and the asymmetry is the delimiter: quoted
    /// lines carry the prefix, the reader's own prose does not. That needs no
    /// label and nothing to match up.
    static func quoted(_ content: String) -> String {
        // A trailing newline would otherwise produce a final bare `>` marking a
        // line the capture does not have.
        var body = content
        if body.hasSuffix("\n") { body.removeLast() }

        return body.components(separatedBy: "\n")
            // `>` alone rather than `> ` for a blank line, so a quote does not
            // ship trailing whitespace on the lines that had none.
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// Relative to the root when the file is under it, absolute otherwise.
    ///
    /// A set may hold files from anywhere — that is what lets a reader open
    /// source beside guidelines from a different tree — so shortening is a
    /// courtesy where it applies and never a claim about where a file lives.
    static func displayPath(for url: URL, root: URL) -> String {
        FilePaths.relativePath(of: url, under: root) ?? url.path
    }
}
