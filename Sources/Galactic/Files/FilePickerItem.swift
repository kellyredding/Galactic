import Foundation

/// One row the picker can offer.
public struct FilePickerItem: Identifiable, Equatable {
    /// Where the row came from, which is what lets the empty list explain
    /// itself: a file you closed is a different suggestion from one you merely
    /// opened, and both are different from a match.
    public enum Source: Equatable {
        /// Closed in this set, most recently first.
        case closed
        /// Opened earlier in the session and still open, or opened and left.
        case recent
        /// Matched from the index against a query.
        case matched
    }

    public let url: URL
    /// What the row displays, relative to the root where that applies.
    public let relativePath: String
    /// Character offsets into `relativePath` that matched, for highlighting.
    /// Empty for a row that was offered rather than matched.
    public let matchedOffsets: [Int]
    public let source: Source

    /// The full path.
    ///
    /// Also the identity, deliberately. A `LazyVStack` keyed on a basename
    /// recycles rows wrongly the moment two files share a name — which in a
    /// repository is immediately.
    public var id: String { url.path }

    public init(
        url: URL,
        relativePath: String,
        matchedOffsets: [Int] = [],
        source: Source
    ) {
        self.url = url
        self.relativePath = relativePath
        self.matchedOffsets = matchedOffsets
        self.source = source
    }
}
