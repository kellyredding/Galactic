import Foundation

/// What a set has had open and closed, most recent first.
///
/// This is the set's history rather than an undo buffer, which is why it is
/// **uncapped in storage**: it is what the empty strip and the empty picker
/// offer, and a reader who closed something an hour ago is exactly who needs it
/// back. Presentation caps it; the record does not.
public struct ClosedTabStack: Equatable {

    /// A file that was open, and where in the strip it sat.
    ///
    /// Both coordinates are a preference, not a promise — see
    /// `FileTabStripModel.reopen`, which falls back a step at a time as the
    /// strip has moved on: to the end of the remembered row when the place in
    /// it has gone, and to the end of the strip when the row itself has.
    ///
    /// The column is recorded because a reader who closes the third of five
    /// tabs and immediately takes it back has undone nothing if it returns
    /// fifth. The row alone was enough while that was the only thing being put
    /// back.
    public struct Entry: Equatable {
        public let url: URL
        public let row: Int
        public let column: Int

        /// Defaulted to the end of the row rather than to zero, which would be
        /// a silent wrong answer: column zero is the *front* of the row, which
        /// is further from where a tab was than the end is. `Int.max` clamps to
        /// whatever the row holds when the tab comes back, so a caller that
        /// does not care gets the behaviour this replaced.
        public init(url: URL, row: Int, column: Int = .max) {
            self.url = url
            self.row = row
            self.column = column
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
    /// read past rather than one they can use. The newest position wins, since
    /// it is where they last had it.
    public mutating func push(url: URL, row: Int, column: Int = .max) {
        entries.removeAll { $0.path == url.path }
        entries.insert(Entry(url: url, row: row, column: column), at: 0)
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
