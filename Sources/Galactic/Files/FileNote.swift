import Foundation

/// A note written against a range of lines in a file on disk.
///
/// Ephemeral by design. It exists while the file is open and is gone when it is
/// sent, deleted, or the tab closes — nothing here is ever written down. That
/// is the whole difference from an artifact annotation, which is persisted,
/// numbered into a review, and fetched back by the agent through a CLI. A note
/// arrives inline in the review that carries it and has no life after.
///
/// Conforms to `ReaderAnnotation`, which is why this feature needs no new
/// annotation surface: the reader takes `annotations:` from its host and builds
/// its cards from them, so an in-memory array serves exactly where a database
/// did. Everything anchor-shaped defaults to nil in the protocol, so a note
/// that is only ever a line range declares the common members and the two line
/// accessors.
public struct FileNote: Identifiable, Equatable {
    public let id: Int64
    /// Per-file and monotonic, for the page's card numbering. Never shipped in
    /// a review — the composer renumbers positionally across every file, so
    /// that "on 2" means the second block a reader can see.
    public let number: Int32
    /// Absolute path of the file this was written against. The store is keyed
    /// by the same string.
    public let filePath: String
    public let startLine: Int32
    public let endLine: Int32
    /// The lines as they read when the note was written. This is what a review
    /// quotes, and it is the reason a note survives the file changing
    /// underneath it.
    public let lineContent: String
    public var content: String
    /// ISO-8601, because that is the shape `ReaderAnnotation` asks for and the
    /// page only ever displays it. Nothing sorts by it — the composer orders
    /// notes by where they sit in the file, not by when they were written.
    public let createdAt: String

    public init(
        id: Int64,
        number: Int32,
        filePath: String,
        startLine: Int32,
        endLine: Int32,
        lineContent: String,
        content: String,
        createdAt: String
    ) {
        self.id = id
        self.number = number
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.lineContent = lineContent
        self.content = content
        self.createdAt = createdAt
    }
}

extension FileNote: ReaderAnnotation {
    public var updatedAt: String { createdAt }

    /// Never stale. A note is written against content frozen at open, so the
    /// document it was fastened to cannot change while it is on screen — and
    /// whether the *file* has changed is a separate question, asked once at
    /// send time by `FileDriftCheck` rather than continuously here.
    public var isStale: Bool { false }

    public var anchorType: ReaderAnchorType { .lineRange }
    public var anchorStartLine: Int32? { startLine }
    public var anchorEndLine: Int32? { endLine }
    public var anchorLineContent: String? { lineContent }
}
