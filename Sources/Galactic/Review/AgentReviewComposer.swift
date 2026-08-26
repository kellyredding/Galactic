import Foundation

/// Turns a set's notes into the one message an agent receives.
///
/// The scrollback's format, extended with a location. Composed
/// in Swift rather than in the page, which is where the scrollback does it,
/// because these notes live in Swift and a review spans files the page on
/// screen does not have.
///
/// Unlike an artifact review, this is **self-contained**: it quotes what it is
/// about instead of handing the agent commands to fetch it. There is nothing to
/// fetch, because nothing was stored.
public enum FileReviewComposer {

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
    public static func compose(
        overallComment: String,
        files: [ReaderFile],
        notes: FileNoteStore,
        root: URL,
        hasDrifted: (ReaderFile) -> Bool = FileDriftCheck.hasDrifted
    ) -> String {
        var blocks: [String] = []
        // Positional across the whole review, 1…N, so a reply saying "on 2" is
        // unambiguous. A note's own number is per file and never ships.
        var position = 1

        for file in files {
            let path = file.url.path
            let fileNotes = notes.notes(forPath: path)
            guard !fileNotes.isEmpty else { continue }

            // Once per file, not once per note: the answer cannot differ
            // between two notes on the same file, and each ask is a stat.
            let drifted = hasDrifted(file)
            let shown = displayPath(for: file.url, root: root)

            for note in fileNotes {
                blocks.append(
                    block(
                        position: position,
                        path: shown,
                        note: note,
                        drifted: drifted
                    )
                )
                position += 1
            }
        }

        guard !blocks.isEmpty else { return "" }

        let body = blocks.joined(separator: blockSeparator)
        let lead = overallComment.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return lead.isEmpty ? body : lead + blockSeparator + body
    }

    /// One note, as the agent sees it.
    ///
    /// Every block carries its own path even though blocks are grouped by file.
    /// Grouping is ordering, not a header — a block quoted back in isolation,
    /// or read after the agent has scrolled, still has to say where it came
    /// from.
    private static func block(
        position: Int,
        path: String,
        note: FileNote,
        drifted: Bool
    ) -> String {
        let range =
            note.startLine == note.endLine
            ? "\(note.startLine)"
            : "\(note.startLine)-\(note.endLine)"
        var location = "[\(position)] \(path):\(range)"
        if drifted { location += " \(driftMarker)" }

        return location + "\n"
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
