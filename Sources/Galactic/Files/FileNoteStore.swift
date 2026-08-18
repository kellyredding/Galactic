import Foundation

/// Every note currently written, for one set of open files.
///
/// In memory and nowhere else. A host holds one of these per set and hands its
/// per-file slice to whichever reader is on screen; when a review is sent the
/// whole thing is emptied. There is no store behind it, no identifier to
/// reconcile, and no path by which a note outlives the window.
///
/// **Keyed by path rather than by open-file identity.** Closing a file and
/// opening it again is a normal thing to do, and it must not be a way to lose
/// a note or to end up with two copies of one. The tab is a view onto this; it
/// does not own anything.
public struct FileNoteStore: Equatable {
    public private(set) var notesByPath: [String: [FileNote]]

    /// Next identifier, and next per-file number, handed out here so a caller
    /// never has to know what has already been used.
    private var nextID: Int64
    private var nextNumberByPath: [String: Int32]

    public init() {
        notesByPath = [:]
        nextID = 1
        nextNumberByPath = [:]
    }

    // MARK: - Reading

    /// Drives the send bar, which counts the whole review rather than the file
    /// on screen — a reader who has annotated three files and is looking at the
    /// fourth still has a review of everything.
    public var totalCount: Int {
        notesByPath.values.reduce(0) { $0 + $1.count }
    }

    /// Drives the badge on one tab.
    public func count(forPath path: String) -> Int {
        notesByPath[path]?.count ?? 0
    }

    /// The notes for one file, in document order.
    ///
    /// Sorted by where they end and then where they start — the scrollback's
    /// comparator, so two surfaces that both number notes agree about what
    /// "first" means.
    public func notes(forPath path: String) -> [FileNote] {
        (notesByPath[path] ?? []).sorted {
            $0.endLine != $1.endLine
                ? $0.endLine < $1.endLine
                : $0.startLine < $1.startLine
        }
    }

    /// One note, found the way the page names it.
    ///
    /// The page reports a per-file `number`, never the store's id — card
    /// numbering is what a reader sees and what the page's own DOM keys on. The
    /// pair is unique for as long as a file is open, because `nextNumberByPath`
    /// only ever increments: a deleted note's number is not handed out again, so
    /// an update arriving for a card that has since gone finds nothing rather
    /// than finding its replacement.
    public func note(forPath path: String, number: Int32) -> FileNote? {
        notesByPath[path]?.first { $0.number == number }
    }

    /// Every path carrying at least one note.
    public var annotatedPaths: [String] {
        notesByPath.filter { !$0.value.isEmpty }.map(\.key)
    }

    // MARK: - Writing

    @discardableResult
    public mutating func add(
        filePath: String,
        startLine: Int32,
        endLine: Int32,
        lineContent: String,
        content: String,
        createdAt: String
    ) -> FileNote {
        let number = nextNumberByPath[filePath] ?? 1
        nextNumberByPath[filePath] = number + 1
        let note = FileNote(
            id: nextID,
            number: number,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            lineContent: lineContent,
            content: content,
            createdAt: createdAt
        )
        nextID += 1
        notesByPath[filePath, default: []].append(note)
        return note
    }

    public mutating func update(id: Int64, content: String) {
        for (path, notes) in notesByPath {
            guard let index = notes.firstIndex(where: { $0.id == id }) else {
                continue
            }
            notesByPath[path]?[index].content = content
            return
        }
    }

    public mutating func delete(id: Int64) {
        for (path, notes) in notesByPath {
            guard notes.contains(where: { $0.id == id }) else { continue }
            notesByPath[path]?.removeAll { $0.id == id }
            if notesByPath[path]?.isEmpty == true {
                notesByPath[path] = nil
            }
            return
        }
    }

    /// One file's notes go, because its tab was closed.
    ///
    /// The numbering goes with them: a file reopened later starts at one again,
    /// which is what a reader who closed it expects. Nothing downstream depends
    /// on a note's own number — the composer renumbers positionally.
    public mutating func drop(path: String) {
        notesByPath[path] = nil
        nextNumberByPath[path] = nil
    }

    /// Everything goes — the review was sent, or the set was switched away.
    public mutating func clear() {
        notesByPath = [:]
        nextNumberByPath = [:]
    }
}
