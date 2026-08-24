import Foundation

/// What a search was asked for. A value, so a run can quote it back.
public struct FileSearchQuery: Equatable, Sendable {
    public let text: String
    public let isCaseSensitive: Bool

    /// Lines of context either side of a matching line. Zero means matching
    /// lines only.
    public let contextLines: Int

    public init(text: String, isCaseSensitive: Bool, contextLines: Int) {
        self.text = text
        self.isCaseSensitive = isCaseSensitive
        self.contextLines = max(0, contextLines)
    }
}

/// One line shown in the results, already split for highlighting.
///
/// The split is done here rather than left to the renderer as offsets, and
/// that is deliberate: the picker's highlight had a defect for exactly this
/// reason — it highlighted one alignment and ranked by another, because two
/// places computed the same positions. A segment list cannot disagree with
/// itself. A context line is one segment with `isMatch` false.
public struct FileSearchLine: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// 1-based, and absolute in the file — the gutter number, the number a
    /// compiler error would quote, the number the reader jumps to.
    public let line: Int
    public let segments: [Segment]

    public init(line: Int, segments: [Segment]) {
        self.line = line
        self.segments = segments
    }

    public var isMatch: Bool { segments.contains { $0.isMatch } }
    public var text: String { segments.map(\.text).joined() }
}

/// One file's worth of results.
public struct FileSearchFileResult: Equatable, Sendable {
    public let path: String
    /// Relative to the root when it is under it, absolute otherwise — the same
    /// rule the review payload uses for the same reason: a path read in
    /// isolation still has to say where it came from.
    public let relativePath: String
    public let matchCount: Int

    /// Contiguous runs of lines, each already merged. A gap between two blocks
    /// is a gap in the file, and the renderer draws it as one.
    public let blocks: [[FileSearchLine]]

    /// True when this file hit its own match cap. `matchCount` is then what is
    /// shown rather than what is there.
    public let wasTruncated: Bool

    public init(
        path: String,
        relativePath: String,
        matchCount: Int,
        blocks: [[FileSearchLine]],
        wasTruncated: Bool
    ) {
        self.path = path
        self.relativePath = relativePath
        self.matchCount = matchCount
        self.blocks = blocks
        self.wasTruncated = wasTruncated
    }
}

/// A whole search, and everything its header has to say.
public struct FileSearchRun: Equatable, Sendable {

    /// Why a run stopped short of the whole root.
    ///
    /// Modelled rather than left implicit, because the alternative — a capped
    /// run that looks complete — reads as "this is everything" when it is not.
    /// The corpus walk already reports truncation for the same reason.
    public enum Truncation: Equatable, Sendable {
        case matchCap(Int)
        case fileCap(Int)
    }

    public let query: FileSearchQuery
    public let root: String
    public let files: [FileSearchFileResult]

    /// Files the index offered.
    public let filesConsidered: Int
    /// Files actually read. Lower than `filesConsidered` by the binaries, the
    /// oversized, and the ones that had gone away.
    public let filesScanned: Int
    public let matchCount: Int
    public let truncation: Truncation?

    /// Directory names the index never held, so the header can say what was
    /// not looked at. A search that quietly skips `log/` reads as a bug later.
    public let skippedNames: [String]

    /// False when the index holds nothing for this root.
    ///
    /// Distinguished from "no matches" because the two are not the same claim
    /// and the wrong one is a lie: an unindexed root returns no files for a
    /// reason that has nothing to do with the query, and a header saying
    /// "0 matches" would be read as "this string is not in your project".
    public let wasRootIndexed: Bool

    public init(
        query: FileSearchQuery,
        root: String,
        files: [FileSearchFileResult],
        filesConsidered: Int,
        filesScanned: Int,
        matchCount: Int,
        truncation: Truncation?,
        skippedNames: [String],
        wasRootIndexed: Bool = true
    ) {
        self.query = query
        self.root = root
        self.files = files
        self.filesConsidered = filesConsidered
        self.filesScanned = filesScanned
        self.matchCount = matchCount
        self.truncation = truncation
        self.skippedNames = skippedNames
        self.wasRootIndexed = wasRootIndexed
    }

    public var isEmpty: Bool { files.isEmpty }
}
