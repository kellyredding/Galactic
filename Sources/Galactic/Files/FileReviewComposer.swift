import Foundation

/// Turns a set's notes into the one message an agent receives.
///
/// The scrollback's format, extended with a location and a language. Composed
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
            let language = FileKind.highlightLanguage(forFilename: path) ?? ""

            for note in fileNotes {
                blocks.append(
                    block(
                        position: position,
                        path: shown,
                        note: note,
                        language: language,
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
        language: String,
        drifted: Bool
    ) -> String {
        let range =
            note.startLine == note.endLine
            ? "\(note.startLine)"
            : "\(note.startLine)-\(note.endLine)"
        var location = "[\(position)] \(path):\(range)"
        if drifted { location += " \(driftMarker)" }

        return location + "\n"
            + "```\(language)\n"
            + note.lineContent + "\n"
            + "```\n"
            + note.content
    }

    /// Relative to the root when the file is under it, absolute otherwise.
    ///
    /// A set may hold files from anywhere — that is what lets a reader open
    /// source beside guidelines from a different tree — so shortening is a
    /// courtesy where it applies and never a claim about where a file lives.
    static func displayPath(for url: URL, root: URL) -> String {
        let path = url.path
        var prefix = root.path
        if !prefix.hasSuffix("/") { prefix += "/" }
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
