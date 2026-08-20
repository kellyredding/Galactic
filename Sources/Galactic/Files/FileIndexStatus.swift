import Foundation

/// What one shard of the index looks like to someone being shown it.
///
/// A translation of `FileIndexCatalog.Shard` and nothing more: the catalog row
/// answers what happened, and this answers what to say about it. Kept apart
/// because the interesting cases are indistinguishable by entry count — a shard
/// holding nothing has three possible explanations and only one of them is
/// "there is nothing there".
public struct FileIndexShardStatus: Identifiable, Sendable, Equatable {

    /// Why the shard holds what it holds.
    public enum State: Sendable, Equatable {
        /// Walked completely.
        case indexed
        /// Walked, but directories inside it could not be opened, so the shard
        /// is missing whatever was under them.
        case incomplete(refusedDirectories: Int)
        /// The shard's own directory could not be opened. The count it reports
        /// is whatever an earlier walk managed to publish, not what is there
        /// now.
        case refused(code: Int32?)
        /// Recorded as owed a walk that has not happened. Either nothing has
        /// ever walked it, or a publish lost the writer lease and left a marker.
        case awaitingWalk
    }

    public var id: String { name }

    /// The shard name as the index stores it. Empty means the entries sitting
    /// directly in the root.
    public let name: String
    public let entryCount: Int
    /// Absent when the shard has never been walked to completion.
    public let walkedAt: Date?
    public let state: State
    /// Whether reading this directory costs a consent dialog.
    public let isConsentProtected: Bool

    /// What to show as the row's title.
    public var displayName: String { name.isEmpty ? "Root files" : name }

    /// Whether anything was withheld from the last walk.
    public var isComplete: Bool {
        switch state {
        case .indexed: return true
        case .incomplete, .refused, .awaitingWalk: return false
        }
    }

    public init(
        name: String, entryCount: Int, walkedAt: Date?, state: State,
        isConsentProtected: Bool
    ) {
        self.name = name
        self.entryCount = entryCount
        self.walkedAt = walkedAt
        self.state = state
        self.isConsentProtected = isConsentProtected
    }
}

/// Everything the index knows about one root, arranged for display.
public struct FileIndexRootStatus: Sendable, Equatable {
    public let root: String
    public let shards: [FileIndexShardStatus]

    public var totalEntries: Int { shards.reduce(0) { $0 + $1.entryCount } }

    /// The shards a reader would want to act on, worst first.
    ///
    /// A refused shard outranks an incomplete one because it is reporting a
    /// count that predates the refusal, which is the most misleading thing on
    /// the screen.
    public var needingAttention: [FileIndexShardStatus] {
        shards
            .filter { !$0.isComplete }
            .sorted { Self.severity($0.state) > Self.severity($1.state) }
    }

    private static func severity(_ state: FileIndexShardStatus.State) -> Int {
        switch state {
        case .refused: return 3
        case .awaitingWalk: return 2
        case .incomplete: return 1
        case .indexed: return 0
        }
    }

    public init(root: String, shards: [FileIndexShardStatus]) {
        self.root = root
        self.shards = shards
    }
}

/// Turning catalog rows into something sayable.
public enum FileIndexStatusReport {

    /// A shard whose generation is zero has never published anything, so its
    /// entry count is a placeholder rather than a measurement — reported as
    /// awaiting a walk even when a refusal is also recorded, because "we have
    /// never read this" is the more useful thing to say first.
    public static func status(
        for shard: FileIndexCatalog.Shard, root: String
    ) -> FileIndexShardStatus {
        let state: FileIndexShardStatus.State
        if shard.isRefused {
            state = .refused(code: shard.refusalCode)
        } else if shard.generation == 0 {
            state = .awaitingWalk
        } else if shard.refusedDirectoryCount > 0 {
            state = .incomplete(refusedDirectories: shard.refusedDirectoryCount)
        } else {
            state = .indexed
        }
        return FileIndexShardStatus(
            name: shard.name,
            entryCount: shard.entryCount,
            walkedAt: shard.generation == 0 && !shard.isRefused
                ? nil : shard.walkedAt,
            state: state,
            isConsentProtected: FileCorpusBuilder.isConsentProtected(
                shard: shard.name, underCanonicalRoot: root
            )
        )
    }

    public static func report(
        for shards: [FileIndexCatalog.Shard], root: String
    ) -> FileIndexRootStatus {
        FileIndexRootStatus(
            root: root,
            shards: shards.map { status(for: $0, root: root) }
        )
    }

    /// How the index describes a refusal to someone who did not cause it.
    ///
    /// `EPERM` from a consent-protected directory is macOS declining on the
    /// user's recorded behalf, which a file mode cannot explain and chmod cannot
    /// fix — so the two are worth separate sentences even though both arrive as
    /// a refused `open`.
    public static func explanation(
        code: Int32?, isConsentProtected: Bool
    ) -> String {
        if isConsentProtected {
            return "macOS has not granted access to this folder"
        }
        switch code {
        case EACCES: return "Permission denied by file permissions"
        case EPERM: return "Access is not permitted"
        default: return "Could not be opened"
        }
    }
}
