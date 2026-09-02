import Foundation

/// What the main actor is allowed to know about the index.
///
/// The store owns mutable state and does expensive work; a view answering a
/// keystroke needs neither, only the last published answer. Keeping that
/// answer here is what lets the two live on different isolation: the store
/// became an actor because a burst of file-system events used to hold the main
/// actor for minutes, and the reads could not follow it there because three of
/// them happen inside functions that set published properties — putting an
/// `await` in front of those introduces a suspension point between deciding
/// which root to read and reading it, which is the one thing the scan is
/// written to rely on not happening.
///
/// Every field of a published state is a value or a reference to something
/// already immutable — a corpus is fixed once built, a removal set is an
/// array, the overlay appears only as a count — so a reader cannot see one
/// change under it, and publishing costs a dictionary of references.
///
/// A lock rather than an isolation domain, and deliberately so. Making this
/// main-actor isolated would have been the obvious reading of "the reads stay
/// where the views are", and it costs more than it looks: the store would then
/// have to hop to publish, so a file created and reported would not be
/// searchable until the next turn of the main actor. That is a real weakening
/// of what the store used to guarantee, and it is unnecessary — what is being
/// handed over is immutable, so the only thing needed is that a reader not see
/// a half-written set of dictionaries. A lock says exactly that, and says it
/// to every isolation at once.
public final class FileIndexSnapshot: @unchecked Sendable {

    public static let shared = FileIndexSnapshot()

    /// Held only across the three assignments and the three reads, never
    /// across any work: what comes out is immutable and is scanned after the
    /// lock is gone.
    private let lock = NSLock()

    /// What a reader needs, and nothing that mutates.
    public struct RootReadState: Sendable {
        public var shards: [String: FileCorpus] = [:]
        public var removed: [String: [UInt64]] = [:]
        public var delta: FileCorpus?
        public var walkingShards: Set<String> = []
        public var addedCount = 0
        public var progress = 0

        public init() {}
    }

    private var readStates: [String: RootReadState] = [:]
    /// A root being browsed → the indexed root that already contains it.
    private var servedBy: [String: String] = [:]
    /// The list each root's last walk resolved, for a caller that only reads.
    private var skipLists: [String: Set<String>] = [:]

    init() {}

    // MARK: - Publishing

    /// Replace everything the main actor knows, in one assignment.
    ///
    /// Whole rather than per-root: the three dictionaries have to agree with
    /// each other — `servedBy` names a root that `readStates` must hold — and
    /// an interleaved update that carried one without the others would answer
    /// a query about a subtree from a root that had gone.
    public func publish(
        readStates: [String: RootReadState],
        servedBy: [String: String],
        skipLists: [String: Set<String>]
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.readStates = readStates
        self.servedBy = servedBy
        self.skipLists = skipLists
    }

    /// The three together, because they have to agree: `servedBy` names a root
    /// that `readStates` must hold, and answering from one taken before a
    /// publish and one taken after would resolve a subtree against a root that
    /// had gone.
    private func current()
        -> (
            readStates: [String: RootReadState], servedBy: [String: String],
            skipLists: [String: Set<String>]
        )
    {
        lock.lock()
        defer { lock.unlock() }
        return (readStates, servedBy, skipLists)
    }

    // MARK: - Reading

    public func slices(forCanonicalRoot root: String) -> [FileMatcher.Slice] {
        let held = current()
        return Self.slices(
            forCanonicalRoot: root, readStates: held.readStates,
            servedBy: held.servedBy
        )
    }

    public func isWalking(_ root: String) -> Bool {
        !(current().readStates[root]?.walkingShards.isEmpty ?? true)
    }

    public func hasCorpus(forCanonicalRoot root: String) -> Bool {
        let held = current()
        return Self.hasCorpus(
            forCanonicalRoot: root, readStates: held.readStates,
            servedBy: held.servedBy
        )
    }

    /// How many entries the overlay is carrying — files seen created since
    /// their shard was written. A number that only grows is the symptom of a
    /// sweep that is not reaching them.
    public func pendingOverlayCount(forCanonicalRoot root: String) -> Int {
        current().readStates[root]?.addedCount ?? 0
    }

    public func indexedCount(forCanonicalRoot root: String) -> Int {
        let held = current()
        return Self.indexedCount(
            forCanonicalRoot: root, readStates: held.readStates,
            servedBy: held.servedBy
        )
    }

    /// The skip list the root's last walk resolved.
    ///
    /// A published copy rather than a read-through, because the read-through
    /// queries the catalog and a search should not pay a database read to
    /// learn something a walk already decided.
    public func skipList(forCanonicalRoot root: String) -> Set<String> {
        current().skipLists[root] ?? []
    }

    // MARK: - The computations themselves
    //
    // Free of isolation so the store can answer the same questions about its
    // own state without either side keeping a second copy of how. The store
    // needs them internally — a walk logs an entry count, and deciding whether
    // a root covers a subtree asks whether it holds any slices — and a reader
    // needs them on the main actor.

    /// Everything the matcher should scan for a root: each shard with its
    /// removals, plus the delta of files created since.
    nonisolated static func slices(
        forCanonicalRoot root: String,
        readStates: [String: RootReadState],
        servedBy: [String: String]
    ) -> [FileMatcher.Slice] {
        // Served by a root above this one: scan that index, restricted to the
        // range this subtree occupies in each of its shards. A shard that does
        // not contain the subtree answers with an empty range and is dropped,
        // so browsing `~/projects` inside an index of `~` scans one shard
        // rather than forty-six.
        if let covering = servedBy[root], let state = readStates[covering] {
            var slices: [FileMatcher.Slice] = []
            for name in state.shards.keys.sorted() {
                guard let corpus = state.shards[name] else { continue }
                let range = corpus.range(underCanonical: root)
                guard !range.isEmpty else { continue }
                slices.append(
                    FileMatcher.Slice(
                        corpus: corpus, removed: state.removed[name],
                        range: range
                    )
                )
            }
            if let delta = state.delta {
                let range = delta.range(underCanonical: root)
                if !range.isEmpty {
                    slices.append(FileMatcher.Slice(corpus: delta, range: range))
                }
            }
            return slices
        }

        guard let state = readStates[root] else { return [] }
        var slices = state.shards.keys.sorted().compactMap { name in
            state.shards[name].map {
                FileMatcher.Slice(corpus: $0, removed: state.removed[name])
            }
        }
        if let delta = state.delta {
            slices.append(FileMatcher.Slice(corpus: delta))
        }
        return slices
    }

    nonisolated static func hasCorpus(
        forCanonicalRoot root: String,
        readStates: [String: RootReadState],
        servedBy: [String: String]
    ) -> Bool {
        if let covering = servedBy[root] {
            return !(readStates[covering]?.shards.isEmpty ?? true)
        }
        return !(readStates[root]?.shards.isEmpty ?? true)
    }

    nonisolated static func indexedCount(
        forCanonicalRoot root: String,
        readStates: [String: RootReadState],
        servedBy: [String: String]
    ) -> Int {
        if servedBy[root] != nil {
            return slices(
                forCanonicalRoot: root, readStates: readStates,
                servedBy: servedBy
            )
            .reduce(0) { $0 + ($1.range?.count ?? $1.corpus.entryCount) }
        }
        guard let state = readStates[root] else { return 0 }
        let live = state.shards.values.reduce(0) { $0 + $1.entryCount }
        return live > 0 ? live + state.addedCount : state.progress
    }
}
