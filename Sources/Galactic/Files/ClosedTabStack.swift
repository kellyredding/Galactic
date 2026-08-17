import Foundation

/// What a set has had open and closed, most recent first.
///
/// This is the set's history rather than an undo buffer, which is why it is
/// **uncapped in storage**: it is what the empty strip and the empty picker
/// offer, and a reader who closed something an hour ago is exactly who needs it
/// back. Presentation caps it; the record does not.
public struct ClosedTabStack: Equatable {

    /// A file that was open, and the row it was in.
    ///
    /// The row is a preference, not a promise — see `FileTabStripModel.reopen`,
    /// which appends when that row has since gone.
    public struct Entry: Equatable {
        public let url: URL
        public let row: Int

        public init(url: URL, row: Int) {
            self.url = url
            self.row = row
        }

        public var path: String { url.path }
    }

    public private(set) var entries: [Entry]

    public init() { entries = [] }

    public var isEmpty: Bool { entries.isEmpty }

    /// Record a closed file, most recent first.
    ///
    /// **Dedupes.** Opening a file again and closing it again is one entry, not
    /// two: a history listing the same file four times is a list a reader has to
    /// read past rather than one they can use. The newest row wins, since it is
    /// where they last had it.
    public mutating func push(url: URL, row: Int) {
        entries.removeAll { $0.path == url.path }
        entries.insert(Entry(url: url, row: row), at: 0)
    }

    /// Take the most recently closed file back off — what ⇧⌘T reaches for.
    public mutating func pop() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Drop an entry because it has been reopened another way — from the
    /// picker, or from a review. Otherwise it would sit in the history claiming
    /// to be closed while its tab was on screen.
    public mutating func remove(url: URL) {
        entries.removeAll { $0.path == url.path }
    }

    /// The window a reader is shown, newest first.
    public func presented(limit: Int = 20) -> [Entry] {
        Array(entries.prefix(max(0, limit)))
    }
}
