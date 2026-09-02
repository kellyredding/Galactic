import Foundation

/// The index every Galactic application shares: which roots are covered, the
/// shards each divides into, and what has changed since those shards were
/// written.
///
/// ### Why ownership is here rather than in the presenter
///
/// The presenter is per-modal and the corpus is not. Assist Ant hides that —
/// one window, one picker, one root — but Galaxy is a session per tab, each
/// with its own working directory, and per-presenter corpora there would mean
/// several copies of the same tree resident at once and several walks
/// competing to build them.
///
/// ### Three tiers, and why
///
/// 1. **Shards on disk**, mapped rather than read. A launch that finds them
///    pays no walk at all.
/// 2. **A removal bitset per shard**, so a deleted file costs a binary search
///    and one bit rather than a twenty-megabyte rewrite.
/// 3. **A delta corpus in memory** for files created since the last walk,
///    scanned alongside the shards as though it were one of them.
///
/// The shards are rewritten on a slow sweep, which folds the other two back
/// in and is also the backstop for events the file system dropped.
@MainActor
public final class FileCorpusStore {

    public static let shared = FileCorpusStore()

    private struct RootState {
        var url: URL
        /// A list supplied instead of the index's own, or none.
        ///
        /// Absent for a host, which is the point: the list is a property of the
        /// index, and a captured copy is how one application comes to walk under
        /// rules another has since changed. Present only for a caller that wants
        /// a specific walk — a test asking for an unfiltered one.
        var skipListOverride: Set<String>?
        /// The list the last walk resolved, for the event path to filter against.
        ///
        /// The walk reads the list through from the index every time, because a
        /// walk happens at most once a minute and the durable shard it publishes
        /// must be built under current rules. Events are the opposite: dozens of
        /// batches a second during a build, and a query per batch on the main
        /// actor is the shape of stall this store has already been fixed for
        /// once.
        ///
        /// So the overlay filters against whatever the last walk resolved. The
        /// cost of being briefly behind is an overlay entry that should have
        /// been skipped, or one that should not have been — and the next walk of
        /// that shard corrects it either way, because the walk is the thing that
        /// decides what the shard contains.
        var resolvedSkipList: Set<String>?
        /// Shard name → its corpus. The empty name is the root's own entries.
        var shards: [String: FileCorpus] = [:]
        /// Shard name → bitset of entries deleted since it was written.
        var removed: [String: [UInt64]] = [:]
        /// Shard name → the generation this process has mapped.
        ///
        /// The generation is in the shard's filename, so a mapping names one
        /// immutable version and never has to notice being replaced. That is
        /// what makes replacement safe and also what makes it invisible: without
        /// remembering which version is held, there is no way to ask whether a
        /// newer one exists.
        var generations: [String: UInt64] = [:]
        /// Files seen created since the last walk, by relative path.
        var added: [String: (modified: Date?, isDirectory: Bool)] = [:]
        /// `added`, encoded as a corpus so the matcher can scan it unchanged.
        var delta: FileCorpus?
        var walkingShards: Set<String> = []
        var progress = 0
        var isLoaded = false
        /// Shards already known to need a rewalk.
        ///
        /// Marking dirty is idempotent, and during build churn the same subtree
        /// is marked over and over — so without this the store wrote the same
        /// row and logged the same line dozens of times a second. Held in memory
        /// so the transition is what costs, not the condition.
        var dirtyShards: Set<String> = []
        /// Names a mark could not be recorded for, the catalog having no row.
        ///
        /// Deduped for the reason `dirtyShards` is deduped: most of these are
        /// not directories at all — a home directory collected 2,544 marks for
        /// `.claude.json.tmp` files that exist for milliseconds — and without
        /// this each one would cost a write attempt and a log line on every
        /// event rather than once. Cleared when a shard is adopted, which is
        /// the only thing that can change the answer.
        var unmarkableShards: Set<String> = []
    }

    private var roots: [String: RootState] = [:]

    /// A root being browsed → the indexed root that already contains it.
    ///
    /// Sorted order makes a subtree a contiguous range, which is what was
    /// supposed to make nesting free. Without this the store keyed everything
    /// by exact path and re-walked `~/projects` in full while an index of `~`
    /// containing every one of those entries sat beside it.
    private var servedBy: [String: String] = [:]
    /// Held, but re-opened when the index location changes.
    ///
    /// This was a computed property returning a fresh connection on every
    /// access, on the theory that opening is cheap and the calls are rare. The
    /// first half is true; the second stopped being true the moment a caller
    /// appeared in the event path, and then every removed directory paid
    /// `sqlite3_open` plus a schema check plus a write **on the main thread**.
    /// During ordinary build churn that is dozens a second, which is a beach
    /// ball.
    ///
    /// Keyed on the resolved path rather than opened once, because that is what
    /// the per-use version was really protecting: a connection bound for the
    /// life of the process would ignore a host — or a test — pointing the index
    /// somewhere else.
    private var openCatalog: FileIndexCatalog?
    private var openCatalogPath: String?

    private var catalog: FileIndexCatalog? {
        let path = FileIndexPaths.catalogFile.path
        if let openCatalog, openCatalogPath == path { return openCatalog }
        openCatalog = FileIndexCatalog()
        openCatalogPath = path
        return openCatalog
    }
    private let writerLease = FileIndexLock()
    private let log = FileIndexLog.shared

    init() {}

    // MARK: - Reading

    /// Everything the matcher should scan for a root: each shard with its
    /// removals, plus the delta of files created since.
    public func slices(forCanonicalRoot root: String) -> [FileMatcher.Slice] {
        // Served by a root above this one: scan that index, restricted to the
        // range this subtree occupies in each of its shards. A shard that does
        // not contain the subtree answers with an empty range and is dropped,
        // so browsing `~/projects` inside an index of `~` scans one shard
        // rather than forty-six.
        if let covering = servedBy[root], let state = roots[covering] {
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

        guard let state = roots[root] else { return [] }
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

    /// An already-indexed root that contains `root`, if there is one.
    ///
    /// The longest match wins, so browsing deep inside two nested covered
    /// roots uses the nearer one and scans less.
    private func coveringRoot(for root: String) -> String? {
        roots.keys
            .filter { candidate in
                candidate != root
                    && FilePaths.relative(root, under: candidate) != nil
                    && holdsEntries(under: root, in: candidate)
            }
            .max { $0.count < $1.count }
    }

    /// Whether a mapped root actually holds entries beneath `root`.
    ///
    /// Sitting above a path lexically is not the same as having indexed it. A
    /// skip list is the everyday way the two come apart: a root that skips
    /// `projects` contains that path and holds nothing under it, and treating
    /// it as covering means the subtree is served by an index that will answer
    /// every query about it with nothing — while looking, from the outside,
    /// exactly like a subtree that is genuinely empty.
    private func holdsEntries(under root: String, in candidate: String) -> Bool {
        guard let state = roots[candidate] else { return false }
        return state.shards.values.contains {
            !$0.range(underCanonical: root).isEmpty
        }
    }

    /// A root the index on disk already covers, which this process has yet to
    /// map.
    ///
    /// `coveringRoot(for:)` can only answer for roots this process has loaded,
    /// and a host picks its root before anything is loaded — so whichever root
    /// was opened first decided whether the index got reused. Opening a subtree
    /// first found nothing above it, made itself a root, and walked four hundred
    /// thousand entries that an index of the home directory on disk already
    /// held: fifteen seconds of walking on the path a keystroke travels, and a
    /// second copy of those entries kept fresh forever afterwards.
    ///
    /// Only unmapped roots are candidates. The loaded ones are the other
    /// method's answer, and excluding them is also what stops a root whose
    /// shards turn out to be unreadable from being proposed again on the retry.
    private func persistedCoveringRoot(for root: String) -> String? {
        guard let catalog else { return nil }
        return catalog.roots()
            .filter { candidate in
                candidate != root
                    && roots[candidate] == nil
                    && FilePaths.relative(root, under: candidate) != nil
                    && catalog.shards(forRoot: candidate).contains { !$0.dirty }
            }
            .max { $0.count < $1.count }
    }

    /// Drop a subtree's own index once a wider root is answering for it.
    ///
    /// Asked after the wider root is mapped rather than before, and only when
    /// it produced entries for this subtree. A skip list can leave a covering
    /// root genuinely empty here, and discarding the only index that held the
    /// subtree on the strength of a containment test alone would answer a
    /// keystroke with nothing.
    ///
    /// Left behind, these rows are worse than redundant. Nothing sweeps a root
    /// that is served from above, so they age without bound while remaining the
    /// nearest match for anything beneath them — preferred over the fresh index
    /// precisely because they are closer.
    private func retireIfRedundant(coveredRoot root: String, by covering: String) {
        guard let catalog, servedBy[root] == covering else { return }
        let shards = catalog.shards(forRoot: root)
        guard !shards.isEmpty, !slices(forCanonicalRoot: root).isEmpty else {
            return
        }
        catalog.forget(root: root)
        log.record(
            "index",
            [
                ("root", root),
                ("event", "retired"),
                ("by", covering),
                ("shards", "\(shards.count)"),
                ("entries", "\(shards.reduce(0) { $0 + $1.entryCount })"),
            ]
        )
    }

    /// Whether a dirty mark is worth writing down.
    ///
    /// Suppressing a repeat is the point of the dedupe: the condition is cheap
    /// to re-derive and the response is not — a database write and a log line
    /// per repetition, on the main thread, for a fact that has not changed.
    ///
    /// A walk in flight is the exception, and it is not an optimisation detail.
    /// The publish that ends that walk decides whether to keep the flag by
    /// comparing when the mark was raised against when the walk began, so a
    /// suppressed mark leaves nothing to compare and the flag is cleared by a
    /// corpus built before the change it describes.
    static func shouldRecordMark(alreadyKnown: Bool, isWalking: Bool) -> Bool {
        !alreadyKnown || isWalking
    }

    public func isWalking(_ root: String) -> Bool {
        !(roots[root]?.walkingShards.isEmpty ?? true)
    }

    public func hasCorpus(forCanonicalRoot root: String) -> Bool {
        if let covering = servedBy[root] {
            return !(roots[covering]?.shards.isEmpty ?? true)
        }
        return !(roots[root]?.shards.isEmpty ?? true)
    }

    /// How many entries the overlay is carrying — files seen created since
    /// their shard was written. A number that only grows is the symptom of a
    /// sweep that is not reaching them.
    public func pendingOverlayCount(forCanonicalRoot root: String) -> Int {
        roots[root]?.added.count ?? 0
    }

    public func indexedCount(forCanonicalRoot root: String) -> Int {
        if servedBy[root] != nil {
            return slices(forCanonicalRoot: root)
                .reduce(0) { $0 + ($1.range?.count ?? $1.corpus.entryCount) }
        }
        guard let state = roots[root] else { return 0 }
        let live = state.shards.values.reduce(0) { $0 + $1.entryCount }
        return live > 0 ? live + state.added.count : state.progress
    }

    // MARK: - Building

    /// Ensure a root is indexed: map whatever is already on disk, then walk
    /// whatever is missing.
    /// - Parameter skipList: what not to descend into, or `nil` to let the root
    ///   decide. Passing it is for tests that want an unfiltered walk; a host
    ///   should not, because the answer is a property of the root and supplying
    ///   one per application is what let two of them describe a shared corpus
    ///   differently. It is also easy to get wrong from here: this method
    ///   recurses to index a wider root, and handing that root the list derived
    ///   for the subtree would walk a home directory under a repository's rules.
    public func index(
        root: URL,
        skipping requestedSkipList: Set<String>? = nil,
        onProgress: @escaping (Int) -> Void = { _ in },
        onFinished: @escaping () -> Void = {}
    ) {
        let canonical = FilePaths.canonical(root)

        // Already covered by a root above this one, so there is nothing to
        // walk and nothing to store: the entries are already indexed, and
        // `slices(forCanonicalRoot:)` will restrict to the range they occupy.
        if roots[canonical] == nil, let covering = coveringRoot(for: canonical) {
            servedBy[canonical] = covering
            log.record(
                "index",
                [
                    ("root", canonical),
                    ("event", "covered"),
                    ("by", covering),
                    ("walked", "no"),
                ]
            )
            retireIfRedundant(coveredRoot: canonical, by: covering)
            // Served from the wider root, so it is that root's mappings that
            // have to be current.
            revalidate(canonicalRoot: covering)
            onFinished()
            return
        }

        // The same answer, but from the index rather than from what this
        // process happens to have mapped. Map the wider root and start over:
        // the branch above then applies, so there is one place that decides
        // what covering means. Mapping a home directory is milliseconds
        // against the seconds walking this subtree would cost, and the retry
        // cannot loop, because the root it just mapped stops being a
        // candidate whether or not it produced shards.
        if roots[canonical] == nil,
            let covering = persistedCoveringRoot(for: canonical)
        {
            log.record(
                "index",
                [
                    ("root", canonical),
                    ("event", "mapping-covering"),
                    ("by", covering),
                ]
            )
            index(
                root: URL(fileURLWithPath: covering),
                skipping: requestedSkipList.map { _ in [] },
                onProgress: onProgress
            ) { [self] in
                index(
                    root: root,
                    skipping: requestedSkipList,
                    onProgress: onProgress,
                    onFinished: onFinished
                )
                retireIfRedundant(coveredRoot: canonical, by: covering)
            }
            return
        }
        if roots[canonical] == nil {
            roots[canonical] = RootState(url: root, skipListOverride: requestedSkipList)
        }
        guard roots[canonical]?.isLoaded != true else {
            // Opening is the moment to ask whether what is mapped is still
            // current. Another application may have published since, and a
            // mapping never learns that on its own.
            revalidate(canonicalRoot: canonical)
            onFinished()
            return
        }
        roots[canonical]?.isLoaded = true

        FileIndexPaths.prepare()
        let privacy = FileIndexPaths.privacyHolds()
        log.record(
            "privacy",
            [
                ("backupExcluded", "\(privacy.excludedFromBackup)"),
                ("spotlightMarker", "\(privacy.spotlightMarker)"),
                ("permissions700", "\(privacy.permissions)"),
            ]
        )

        catalog?.adopt(root: canonical)
        reclaimOrphanedShardDirectories()
        let mapped = loadPersistedShards(canonical: canonical)
        log.record(
            "load",
            [
                ("root", canonical),
                ("shards", "\(mapped.count)"),
                ("entries", "\(mapped.reduce(0) { $0 + $1.value.entryCount })"),
            ]
        )

        Task { await walkMissingShards(canonical: canonical, onProgress: onProgress, onFinished: onFinished) }
    }

    /// Map every shard the catalog knows about. Anything unreadable is simply
    /// absent, and absent means "walk it" — a corpus is always rebuildable, so
    /// there is no failure case worth propagating.
    private func loadPersistedShards(canonical: String) -> [String: FileCorpus] {
        guard let catalog else { return [:] }
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        var mapped: [String: FileCorpus] = [:]

        // Reconcile before mapping. A row for a directory the list now excludes
        // would otherwise be mapped on every launch forever: pruning is an
        // action some process takes, and nothing guarantees it ran — an edit
        // interrupted between storing the entry and pruning, or made by an
        // application that is no longer running, leaves the row behind. This is
        // the one place every launch passes through, which makes it the place
        // the index can put itself right.
        let excluded = effectiveSkipList(forCanonicalRoot: canonical)
        for shard in catalog.shards(forRoot: canonical)
        where !shard.name.isEmpty && excluded.contains(shard.name) {
            log.record(
                "prune",
                [
                    ("root", canonical), ("shard", shard.name),
                    ("result", "removed"), ("reason", "skipped-on-load"),
                    ("entries", "\(shard.entryCount)"),
                ]
            )
            catalog.remove(root: canonical, name: shard.name)
            FileCorpusFile.removeAllGenerations(
                shardDirectory: directory,
                shard: FileIndexPaths.rootIdentifier(shard.name)
            )
        }

        // Generation zero means nothing was ever published for this shard — a
        // placeholder for one that is owed a walk or was refused its first. There
        // is no file to map, and attempting one logs an unreadable-shard line on
        // every launch for a directory that is behaving exactly as recorded.
        //
        // **Dirty is not a reason to skip one.** A dirty shard with a generation
        // has a published file; the flag says it is owed a walk, not that what it
        // holds is unusable. Skipping it made a whole subtree unanswerable at
        // load, and the consequence was not a stale result — it was a second
        // root: a picker asking for a subtree the covering root could no longer
        // serve adopted it and walked four hundred thousand entries the index
        // already held. Slightly old beats absent, and the sweep takes dirty
        // shards first anyway.
        for shard in catalog.shards(forRoot: canonical)
        where shard.generation > 0 {
            let url = FileCorpusFile.url(
                shardDirectory: directory,
                shard: FileIndexPaths.rootIdentifier(shard.name),
                generation: shard.generation
            )
            guard let corpus = FileCorpus.load(from: url) else {
                log.record(
                    "load",
                    [("shard", shard.name), ("result", "unreadable"), ("action", "rewalk")]
                )
                continue
            }
            mapped[shard.name] = corpus
            roots[canonical]?.generations[shard.name] = shard.generation
        }
        roots[canonical]?.shards = mapped
        return mapped
    }

    /// Bring mapped shards up to whatever the index now holds.
    ///
    /// A published generation is immutable and replacement is a rename, so a
    /// reader mid-search is never disturbed — the inode outlives the unlink. That
    /// is what makes two applications safe, and also what makes them diverge: if
    /// one publishes generation five, the other keeps answering from four for the
    /// life of its process. Not wrong, but two applications giving different
    /// answers to the same query is what a user reports as a bug in one of them.
    ///
    /// Asked when a picker opens rather than on a timer or a notification. Per
    /// keystroke would be absurd, and a push mechanism is machinery for something
    /// a question at the right moment already answers.
    ///
    /// **Removal bits are dropped rather than carried.** They are indices into
    /// the generation they were gathered against, and the same index means a
    /// different entry in the next one — transferring them would mark unrelated
    /// files deleted. So a deletion this process observed and the newer
    /// generation predates can reappear until an event or a walk settles it. That
    /// is a narrow window, and the alternative is silent corruption of results.
    ///
    /// **The shard is deliberately not marked dirty.** Two applications each
    /// remapping and then requesting a rewalk is a loop: one publishes, the other
    /// rebuilds and publishes, and so on without end. Remapping is the whole
    /// response.
    @discardableResult
    public func revalidate(canonicalRoot root: String) -> [String] {
        guard let catalog, roots[root] != nil else { return [] }
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: root)
        let recorded = catalog.shards(forRoot: root)
        var remapped: [String] = []

        for shard in recorded where !shard.dirty {
            guard roots[root]?.generations[shard.name] != shard.generation else {
                continue
            }
            let url = FileCorpusFile.url(
                shardDirectory: directory,
                shard: FileIndexPaths.rootIdentifier(shard.name),
                generation: shard.generation
            )
            guard let corpus = FileCorpus.load(from: url) else { continue }
            roots[root]?.shards[shard.name] = corpus
            roots[root]?.generations[shard.name] = shard.generation
            roots[root]?.removed[shard.name] = nil
            remapped.append(shard.name)
        }

        // A shard another application pruned has to go here too, or this process
        // keeps offering files from a directory the index has stopped covering.
        let live = Set(recorded.map(\.name))
        for held in roots[root]?.shards.keys.filter({ !live.contains($0) }) ?? [] {
            roots[root]?.shards[held] = nil
            roots[root]?.removed[held] = nil
            roots[root]?.generations[held] = nil
            remapped.append(held)
        }

        if !remapped.isEmpty {
            log.record(
                "revalidate",
                [
                    ("root", root),
                    ("shards", "\(remapped.count)"),
                    ("names", remapped.sorted().prefix(6).joined(separator: ",")),
                ]
            )
        }
        return remapped
    }

    private func walkMissingShards(
        canonical: String,
        onProgress: @escaping (Int) -> Void,
        onFinished: @escaping () -> Void
    ) async {
        guard let state = roots[canonical] else { return }
        let root = state.url
        let skipList = effectiveSkipList(forCanonicalRoot: canonical)

        // The root's own shard first: it is what names all the others.
        if state.shards[""] == nil {
            await walk(shard: "", canonical: canonical, root: root, skipping: skipList, onProgress: onProgress)
        }
        guard let rootShard = roots[canonical]?.shards[""] else {
            onFinished()
            return
        }
        // Filtered here as well as during the walk, because these names come
        // from the root shard rather than from the file system — and that shard
        // was written under whatever list applied when it was last walked. A
        // name the list now excludes would otherwise be handed straight back to
        // `walk`, which opens a shard's own top directory unconditionally: the
        // shard is rebuilt, and pruning it achieves nothing that survives a
        // launch.
        var names: [String] = []
        for index in 0..<rootShard.entryCount where rootShard.isDirectory(at: index) {
            let name = rootShard.relativePath(at: index)
            guard !skipList.contains(name) else { continue }
            names.append(name)
        }

        for name in names where roots[canonical]?.shards[name] == nil {
            await walk(shard: name, canonical: canonical, root: root, skipping: skipList, onProgress: onProgress)
        }
        // Watching and rotating start only once there is an index to keep
        // fresh. Before that there is nothing for an event to update, and a
        // replay would be answering questions about a corpus that does not
        // exist yet.
        watch(canonicalRoot: canonical)
        FileIndexRefreshSweep.shared.add(canonicalRoot: canonical)

        log.record(
            "index",
            [
                ("root", canonical),
                ("event", "ready"),
                ("shards", "\(roots[canonical]?.shards.count ?? 0)"),
                ("entries", "\(indexedCount(forCanonicalRoot: canonical))"),
            ]
        )
        onFinished()
    }

    /// The list to walk a root under, resolved now rather than remembered.
    ///
    /// Derived from what the root is, then adjusted by whatever this index has
    /// been told. Read on every walk, which costs one query and is what lets a
    /// change made in one application take effect in another without either of
    /// them being told: there is no cached copy to go stale.
    ///
    /// A walk already in flight finishes under the list it started with. That is
    /// the same shape as a dirty mark raised mid-walk, and it has the same
    /// answer — changing the list marks the affected shards dirty, so anything
    /// published under superseded rules gets walked again.
    func effectiveSkipList(forCanonicalRoot root: String) -> Set<String> {
        guard let state = roots[root] else { return [] }
        let list: Set<String>
        if let override = state.skipListOverride {
            list = override
        } else {
            var derived = FileCorpusBuilder.skipList(forRoot: state.url)
            if let delta = catalog?.skipListDelta() {
                derived.formUnion(delta.added)
                derived.subtract(delta.removed)
            }
            list = derived
        }
        roots[root]?.resolvedSkipList = list
        return list
    }

    /// The list the event path filters against — the last one a walk resolved.
    ///
    /// Deliberately not a read-through: see `RootState.resolvedSkipList`.
    private func skipListForEvents(canonicalRoot root: String) -> Set<String> {
        guard let state = roots[root] else { return [] }
        if let resolved = state.resolvedSkipList { return resolved }
        return state.skipListOverride
            ?? FileCorpusBuilder.skipList(forRoot: state.url)
    }

    /// Stop indexing a root and reclaim what it was holding.
    ///
    /// Both halves, because either alone is a defect. Forgetting the rows
    /// without reclaiming leaves the shard files on disk with nothing naming
    /// them — thirteen megabytes were orphaned exactly that way by the covering
    /// root retirement. Reclaiming without forgetting deletes files rows still
    /// point at.
    ///
    /// Unmapping in this process too, so a picker open in the meantime stops
    /// answering from a tree the index no longer covers.
    public func stopIndexing(canonicalRoot root: String) {
        guard let catalog else { return }
        let shards = catalog.shards(forRoot: root)
        catalog.forget(root: root)
        roots[root] = nil
        servedBy = servedBy.filter { $0.value != root && $0.key != root }
        let reclaimed = reclaimOrphanedShardDirectories()
        log.record(
            "index",
            [
                ("root", root),
                ("event", "stopped"),
                ("shards", "\(shards.count)"),
                ("entries", "\(shards.reduce(0) { $0 + $1.entryCount })"),
                ("reclaimed", "\(reclaimed)"),
            ]
        )
    }

    /// Delete shard directories no root in the catalog answers for.
    ///
    /// A root that is retired — because a wider one now covers it — keeps its
    /// files: the rows are what make them reachable, and the root that noticed is
    /// the wrong place to decide what another root still needs. So the decision
    /// is made here instead, once, against the whole index, where every root is
    /// visible at the same time.
    ///
    /// Runs at load. Not under the lease: a directory no row names cannot be
    /// opened by anything, since opening one requires reading the generation out
    /// of the catalog first.
    @discardableResult
    func reclaimOrphanedShardDirectories() -> Int {
        guard let catalog else { return 0 }
        let index = FileIndexPaths.indexDirectory
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                atPath: index.path
            )
        else { return 0 }
        let live = Set(catalog.roots().map(FileIndexPaths.rootIdentifier))
        var reclaimed = 0
        for entry in entries where !live.contains(entry) {
            let candidate = index.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: candidate.path, isDirectory: &isDirectory
                ), isDirectory.boolValue
            else { continue }
            let bytes =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: candidate.path
                ).count) ?? 0
            try? FileManager.default.removeItem(at: candidate)
            reclaimed += 1
            log.record(
                "reclaim",
                [
                    ("directory", entry), ("result", "removed"),
                    ("files", "\(bytes)"),
                ]
            )
        }
        return reclaimed
    }

    /// Remove a shard from the index entirely.
    ///
    /// For a top-level directory the skip list now excludes. Rewalking such a
    /// shard rebuilds it: the skip check applies when the walk *descends* into a
    /// directory, so it governs what a shard contains and never whether the
    /// shard exists. Marking it dirty would therefore be a no-op dressed as an
    /// action — the panel's most obvious edit doing nothing at all.
    ///
    /// Takes the writer lease, because unlinking a generation another process is
    /// about to open is the one part of this that is not merely bookkeeping. A
    /// reader already holding a mapping is unharmed either way: the inode
    /// survives unlink until the last mapping drops.
    @discardableResult
    public func prune(shard: String, canonicalRoot root: String) -> Bool {
        guard !shard.isEmpty else { return false }
        guard writerLease.acquire() else {
            log.record(
                "prune",
                [
                    ("shard", shard), ("result", "deferred"),
                    ("reason", "another-writer"),
                ]
            )
            return false
        }
        defer { writerLease.release() }

        let held = roots[root]?.shards[shard]?.entryCount ?? 0
        roots[root]?.shards[shard] = nil
        roots[root]?.removed[shard] = nil
        roots[root]?.dirtyShards.remove(shard)
        dropOverlayEntries(under: shard, canonical: root)
        catalog?.remove(root: root, name: shard)
        // The root shard still lists this directory as an entry of its own, so
        // it is now stale by exactly one row. Nothing depends on that being
        // corrected promptly — the guards in `walkMissingShards` and
        // `adoptNewShards` stop the name becoming a shard again — but leaving it
        // would offer a reader a directory the index has stopped covering.
        catalog?.markDirty(root: root, name: "")
        roots[root]?.dirtyShards.insert("")
        FileCorpusFile.removeAllGenerations(
            shardDirectory: FileIndexPaths.shardDirectory(forCanonicalRoot: root),
            shard: FileIndexPaths.rootIdentifier(shard)
        )
        log.record(
            "prune",
            [
                ("root", root), ("shard", shard), ("result", "removed"),
                ("entries", "\(held)"),
            ]
        )
        return true
    }

    /// Walk one shard, publish it, and record it.
    private func walk(
        shard: String,
        canonical: String,
        root: URL,
        skipping skipList: Set<String>,
        onProgress: @escaping (Int) -> Void
    ) async {
        guard roots[canonical]?.walkingShards.contains(shard) != true else { return }
        roots[canonical]?.walkingShards.insert(shard)
        let started = Date()
        let alreadyHeld = roots[canonical]?.shards.values.reduce(0) { $0 + $1.entryCount } ?? 0

        let walked = await Task.detached(priority: .utility) {
            FileCorpusBuilder.buildShard(
                root: root,
                shard: shard,
                skipping: skipList,
                onProgress: { count in
                    Task { @MainActor in
                        FileCorpusStore.shared.report(alreadyHeld + count, for: canonical)
                        onProgress(alreadyHeld + count)
                    }
                }
            )
        }.value

        // A refused top directory is not an empty one, and the corpus looks the
        // same either way. Keeping what is already mapped and declining to
        // publish is the only safe reading: the alternative replaces a working
        // index with nothing, records success, and leaves the reader searching a
        // directory the picker now believes is empty.
        if walked.rootWasRefused {
            roots[canonical]?.walkingShards.remove(shard)
            roots[canonical]?.dirtyShards.remove(shard)
            // Attempted, so it stops being chosen every tick. A timer cannot
            // succeed where permission is the obstacle, and retrying on one
            // costs a dialog per attempt. The way back is an explicit refresh.
            catalog?.noteWalkRefused(
                root: canonical, name: shard,
                code: walked.rootRefusal?.code ?? 0
            )
            log.record(
                "walk",
                [
                    ("root", canonical),
                    ("shard", shard.isEmpty ? "(root)" : shard),
                    ("result", "refused"),
                    ("code", "\(walked.rootRefusal?.code ?? 0)"),
                    ("held", "\(roots[canonical]?.shards[shard]?.entryCount ?? 0)"),
                    ("seconds", String(format: "%.2f", Date().timeIntervalSince(started))),
                ]
            )
            return
        }

        let corpus = walked.corpus
        if !walked.refusedDirectories.isEmpty {
            log.record(
                "walk",
                [
                    ("shard", shard.isEmpty ? "(root)" : shard),
                    ("result", "partial"),
                    ("refused", "\(walked.refusedDirectories.count)"),
                ]
            )
        }
        roots[canonical]?.shards[shard] = corpus
        roots[canonical]?.removed[shard] = nil
        roots[canonical]?.walkingShards.remove(shard)
        // Whatever made it dirty has now been answered by walking it, so the
        // next event that would mark it dirty should be allowed to say so.
        roots[canonical]?.dirtyShards.remove(shard)
        dropOverlayEntries(under: shard, canonical: canonical)

        let elapsed = Date().timeIntervalSince(started)
        publish(
            corpus, shard: shard, canonical: canonical, walkStartedAt: started,
            encounteredSkips: walked.encounteredSkips,
            refusedDirectoryCount: walked.refusedDirectories.count
        )

        // The root's shard names all the others, so walking it is also how a
        // directory created *since* the last walk acquires a shard of its own.
        // Without this its files would live in the overlay indefinitely: the
        // results stay correct, but the delta grows without bound and nothing
        // ever folds it in, because folding happens when a shard is walked and
        // there is no shard.
        if shard.isEmpty {
            await adoptNewShards(
                canonical: canonical, root: root, skipping: skipList,
                onProgress: onProgress
            )
        }
        log.record(
            "walk",
            [
                ("root", canonical),
                ("shard", shard.isEmpty ? "(root)" : shard),
                ("entries", "\(corpus.entryCount)"),
                ("seconds", String(format: "%.2f", elapsed)),
            ]
        )
    }

    /// Walk any top-level directory that has appeared since the last time the
    /// root's own shard was written.
    private func adoptNewShards(
        canonical: String, root: URL, skipping skipList: Set<String>,
        onProgress: @escaping (Int) -> Void = { _ in }
    ) async {
        guard let rootShard = roots[canonical]?.shards[""] else { return }
        var names: [String] = []
        for index in 0..<rootShard.entryCount where rootShard.isDirectory(at: index) {
            let name = rootShard.relativePath(at: index)
            guard !skipList.contains(name) else { continue }
            if roots[canonical]?.shards[name] == nil { names.append(name) }
        }
        guard !names.isEmpty else { return }
        log.record(
            "index",
            [("event", "new-subtrees"), ("count", "\(names.count)"),
             ("names", names.prefix(6).joined(separator: ","))]
        )
        for name in names {
            await walk(
                shard: name, canonical: canonical, root: root,
                skipping: skipList, onProgress: onProgress
            )
        }
    }

    /// Write a shard and record the new generation.
    private func publish(
        _ corpus: FileCorpus, shard: String, canonical: String,
        walkStartedAt: Date, encounteredSkips: Set<String>,
        refusedDirectoryCount: Int = 0
    ) {
        guard let catalog else { return }
        // Held for the write and released immediately after, rather than for
        // the life of the process.
        //
        // A lease taken once and kept would mean whichever application
        // launched first owned the index forever: the second would still work,
        // because it walks in memory, but it could never persist what it
        // walked — so it would pay the full walk on every launch while the
        // first paid none. Per-publish is short enough that two applications
        // interleave without either waiting.
        guard writerLease.acquire() else {
            // Deferred is only survivable if something comes back for it. The
            // lease does not wait, this runs on the main actor so it must not
            // wait either, and the corpus that was just walked lives only in
            // this process's memory — so the shard is recorded as owed, and the
            // sweep, which takes dirty shards first, is what returns to it.
            // Without this the shard is absent from the index for the life of
            // the installation, rewalked every launch and published by nobody.
            catalog.markPending(root: canonical, name: shard)
            log.record(
                "publish",
                [
                    ("shard", shard), ("result", "deferred"),
                    ("reason", "another-writer"), ("action", "marked-pending"),
                ]
            )
            return
        }
        defer { writerLease.release() }
        let previous = catalog.shards(forRoot: canonical).first { $0.name == shard }
        let generation = (previous?.generation ?? 0) + 1
        let directory = FileIndexPaths.shardDirectory(forCanonicalRoot: canonical)
        let identifier = FileIndexPaths.rootIdentifier(shard)
        let url = FileCorpusFile.url(
            shardDirectory: directory, shard: identifier, generation: generation
        )
        do {
            let bytes = try FileCorpusFile.write(corpus, to: url)
            catalog.record(
                root: canonical, name: shard, generation: generation,
                entryCount: corpus.entryCount, walkStartedAt: walkStartedAt,
                eventsUUID: FileIndexWatcher.volumeUUID(for: canonical),
                eventsID: FileIndexWatcher.currentEventID(),
                refusedDirectoryCount: refusedDirectoryCount
            )
            catalog.recordEncounteredSkips(
                root: canonical, shard: shard, names: encounteredSkips
            )
            // Recorded so a later revalidation knows this process is already
            // holding what it just wrote, rather than remapping its own work.
            roots[canonical]?.generations[shard] = generation
            FileCorpusFile.removeSupersededGenerations(
                shardDirectory: directory, shard: identifier, keeping: generation
            )
            log.record(
                "publish",
                [
                    ("shard", shard.isEmpty ? "(root)" : shard),
                    ("generation", "\(generation)"),
                    ("entries", "\(corpus.entryCount)"),
                    ("bytes", "\(bytes)"),
                ]
            )
        } catch {
            log.record(
                "publish",
                [("shard", shard), ("result", "failed"), ("error", "\(error)")]
            )
        }
    }

    private func report(_ count: Int, for root: String) {
        roots[root]?.progress = count
    }

    // MARK: - Live updates

    /// Record files that appeared. Cheap: they go into a small in-memory
    /// corpus scanned alongside the shards, rather than provoking a rewalk.
    /// One path the file system says exists, with what a `stat` already said
    /// about it.
    ///
    /// The kind and the modification time are carried rather than looked up
    /// again. Measured: `stat` was **213 ms of a 218 ms** burst of nine hundred
    /// paths — ninety-eight percent of the cost, on the main actor, at a quarter
    /// of a millisecond each because the paths are scattered across a
    /// 877,000-file tree and each one is a cold metadata read. The watcher has
    /// already paid for that off the main actor to decide whether the path still
    /// exists, so paying again here was pure duplication.
    public struct Appearance {
        public let path: String
        public let modified: Date?
        public let isDirectory: Bool

        public init(path: String, modified: Date?, isDirectory: Bool) {
            self.path = path
            self.modified = modified
            self.isDirectory = isDirectory
        }
    }

    /// Convenience for a caller holding only paths — it stats them itself.
    ///
    /// Fine for a handful. The watcher does not use it, because a burst is not
    /// a handful.
    public func noteCreated(_ paths: [String], canonicalRoot root: String) {
        noteCreated(
            paths.compactMap { path in
                var info = stat()
                guard stat(path, &info) == 0 else { return nil }
                return Appearance(
                    path: path,
                    modified: Date(
                        timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    ),
                    isDirectory: info.st_mode & S_IFMT == S_IFDIR
                )
            },
            canonicalRoot: root
        )
    }

    public func noteCreated(_ appearances: [Appearance], canonicalRoot root: String) {
        guard var state = roots[root] else { return }
        // Once per batch, not once per path.
        let eventSkipList = skipListForEvents(canonicalRoot: root)
        var changed = 0
        for appearance in appearances {
            let path = appearance.path
            guard
                let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
            else { continue }
            let isDirectory = appearance.isDirectory
            // A path that a shard already holds and that was merely marked
            // deleted comes back by clearing the bit — it must NOT also join
            // the delta, or the file is offered twice, once from each. This is
            // the everyday save-in-place pattern: many editors write a new
            // file and rename it over the old one, which arrives here as a
            // delete followed by a create of a path the shard already knows.
            // The walk's skip list applies here too, and forgetting it is
            // expensive in a way that is easy to miss: the file system reports
            // every path, including the build directories and dependency trees
            // the walk deliberately refuses. Left unfiltered, a single compile
            // put eleven thousand entries into the overlay — precisely the
            // noise the skip list exists to keep out, arriving through the
            // other door.
            guard Self.isIndexable(relative, skipping: eventSkipList) else {
                continue
            }
            if clearRemoval(of: relative, in: &state) {
                changed += 1
                continue
            }
            if state.added[relative] == nil { changed += 1 }
            state.added[relative] = (appearance.modified, isDirectory)
        }
        roots[root] = state
        if changed > 0 {
            rebuildDelta(root: root)
            log.record("watch", watchFields("created", changed: changed, root: root))
            applyCompactionPressure(root: root)
        }
    }

    /// Record files that went away, by setting a bit rather than rewriting a
    /// shard.
    public func noteRemoved(_ paths: [String], canonicalRoot root: String) {
        guard var state = roots[root] else { return }
        var changed = 0
        var vanishedDirectories: [String] = []
        for path in paths {
            guard
                let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
            else { continue }
            if state.added.removeValue(forKey: relative) != nil { changed += 1 }
            let outcome = markRemoved(relative, in: &state)
            if outcome.removed { changed += 1 }
            if outcome.wasDirectory { vanishedDirectories.append(relative) }
        }
        roots[root] = state
        if changed > 0 {
            rebuildDelta(root: root)
            log.record("watch", watchFields("removed", changed: changed, root: root))
        }

        // A directory that went away takes everything under it, and the file
        // system does not say so: its children never changed, so no event
        // mentions them. Clearing one bit for the directory itself would leave
        // every path beneath it resolving to nothing.
        //
        // The honest response is the same one a dropped event gets — mark the
        // subtree for a rewalk and let the sweep take it on the next tick,
        // rather than pretending a bitset can express "and all descendants".
        // A renamed directory arrives as exactly this, plus a create.
        for directory in vanishedDirectories {
            markSubtreeDirty(
                root + "/" + directory, canonicalRoot: root, reason: "directory-removed"
            )
        }
    }

    /// The overlay, broken down by the shard each entry belongs to.
    ///
    /// Also the answer to "why is `pending` three hundred", which the log could
    /// not give before: a count with no attribution says something is
    /// accumulating without saying where.
    public func overlayByShard(forCanonicalRoot root: String) -> [String: Int] {
        guard let state = roots[root] else { return [:] }
        var counts: [String: Int] = [:]
        for path in state.added.keys {
            let shard = path.contains("/")
                ? String(path.split(separator: "/")[0]) : ""
            counts[shard, default: 0] += 1
        }
        return counts
    }

    private func watchFields(
        _ event: String, changed: Int, root: String
    ) -> [(String, String)] {
        var fields = [
            ("event", event),
            ("count", "\(changed)"),
            ("pending", "\(roots[root]?.added.count ?? 0)"),
        ]
        if let top = overlayByShard(forCanonicalRoot: root)
            .max(by: { $0.value < $1.value })
        {
            fields.append(("top", "\(top.key.isEmpty ? "(root)" : top.key):\(top.value)"))
        }
        return fields
    }

    /// How many pending entries one shard may accumulate before it is rewritten.
    ///
    /// The overlay was bounded only by time: it drained when the sweep got
    /// around to a shard, which is an hour at the earliest. So an active hour
    /// grew it without limit, and `rebuildDelta` re-encodes the whole thing on
    /// every batch of events — an O(n) rebuild arriving every half second, which
    /// is the same shape as the re-rank storm this effort began by removing.
    ///
    /// Bounding it by size as well turns the overlay into what it should have
    /// been from the start: a buffer that provokes its own compaction. The
    /// number is deliberately well above ordinary editing and well below the
    /// point where the rebuild is felt.
    static let overlayCompactionThreshold = 500

    /// Mark any shard carrying too much overlay for a rewalk.
    ///
    /// Dirty shards already jump the sweep queue, so this needs no scheduler
    /// of its own: it converts "the overlay is large" into "this subtree is
    /// stale", which is a thing the sweep already knows how to fix.
    private func applyCompactionPressure(root: String) {
        for (shard, count) in overlayByShard(forCanonicalRoot: root)
        where count >= Self.overlayCompactionThreshold {
            // Once is enough, for the same reason as `markSubtreeDirty`: the
            // overlay stays over the threshold until the rewalk happens, so
            // every subsequent batch would re-mark and re-log a standing fact.
            guard roots[root]?.dirtyShards.contains(shard) != true else { continue }
            guard
                roots[root]?.unmarkableShards.contains(shard) != true
            else { continue }

            // Record the suppression only once the mark is durable. The guard
            // above is what makes the order load-bearing: a shard remembered
            // as marked is not marked again, so one remembered after a mark
            // that landed nowhere is retired permanently. A dependency cache
            // stranded 24,278 entries exactly that way.
            guard catalog?.markDirty(root: root, name: shard) == true else {
                roots[root]?.unmarkableShards.insert(shard)
                log.record(
                    "refresh",
                    [
                        ("event", "compaction-mark-lost"),
                        ("shard", shard.isEmpty ? "(root)" : shard),
                        ("pending", "\(count)"),
                    ]
                )
                continue
            }
            roots[root]?.dirtyShards.insert(shard)
            log.record(
                "refresh",
                [
                    ("event", "compaction-due"),
                    ("shard", shard.isEmpty ? "(root)" : shard),
                    ("pending", "\(count)"),
                    ("threshold", "\(Self.overlayCompactionThreshold)"),
                ]
            )
        }
    }

    /// Whether a path the file system mentioned belongs in the index.
    ///
    /// Any component naming a skipped directory disqualifies it, which is the
    /// same rule the walk applies by refusing to descend.
    static func isIndexable(_ relative: String, skipping skipList: Set<String>)
        -> Bool
    {
        guard !skipList.isEmpty else { return true }
        for component in relative.split(separator: "/").dropLast()
        where skipList.contains(String(component)) {
            return false
        }
        return true
    }

    /// Mark one entry deleted, and say whether it was a directory.
    ///
    /// The kind matters to the caller: a bitset can hide one entry, and a
    /// directory standing for everything beneath it is not one entry.
    /// Which shard could hold this path, without looking.
    ///
    /// A shard is a top-level subtree and every entry in it is prefixed with
    /// that name, so the first path component *is* the shard — and a path with
    /// no separator is a top-level entry, which lives in the root's own shard.
    ///
    /// This is not a micro-optimisation. Both callers used to ask every shard
    /// in turn, and each question is a binary search that replays a
    /// front-coded block per probe. Measured on this machine: eighty-four event
    /// batches arrived in one second after a relaunch, and searching
    /// forty-five shards per path in each of them put roughly fifty million
    /// decode steps on the main thread inside that second. That is a beach
    /// ball, and it is what the arithmetic predicts rather than what a profiler
    /// found afterwards.
    private static func shardName(covering relative: String) -> String {
        guard let separator = relative.firstIndex(of: "/") else { return "" }
        return String(relative[relative.startIndex..<separator])
    }

    private func markRemoved(_ relative: String, in state: inout RootState)
        -> (removed: Bool, wasDirectory: Bool)
    {
        let name = Self.shardName(covering: relative)
        guard let corpus = state.shards[name] else { return (false, false) }
        let needle = Array(relative.utf8)
        let index = corpus.firstIndex(atOrAfter: needle)
        guard index < corpus.entryCount,
            corpus.relativePath(at: index) == relative
        else { return (false, false) }

        var bits =
            state.removed[name]
            ?? [UInt64](repeating: 0, count: (corpus.entryCount + 63) / 64)
        bits[index >> 6] |= 1 << UInt64(index & 63)
        state.removed[name] = bits
        return (true, corpus.isDirectory(at: index))
    }

    /// Un-delete a path a shard already holds.
    ///
    /// Returns whether a shard covers this path, which is what tells the
    /// caller not to add it to the delta as well.
    @discardableResult
    private func clearRemoval(of relative: String, in state: inout RootState)
        -> Bool
    {
        let name = Self.shardName(covering: relative)
        guard let corpus = state.shards[name] else { return false }
        let needle = Array(relative.utf8)
        let index = corpus.firstIndex(atOrAfter: needle)
        guard index < corpus.entryCount,
            corpus.relativePath(at: index) == relative
        else { return false }

        if state.removed[name] != nil {
            state.removed[name]?[index >> 6] &= ~(1 << UInt64(index & 63))
        }
        return true
    }

    /// Anything the overlay was carrying for a shard is now in the shard.
    private func dropOverlayEntries(under shard: String, canonical: String) {
        guard var state = roots[canonical] else { return }
        let prefix = shard.isEmpty ? "" : shard + "/"
        state.added = state.added.filter { key, _ in
            shard.isEmpty ? key.contains("/") : !key.hasPrefix(prefix)
        }
        roots[canonical] = state
        rebuildDelta(root: canonical)
    }

    /// Re-encode the pending additions as a corpus.
    ///
    /// Rebuilt whole rather than appended to, because a corpus is immutable
    /// once built, which is what lets a scan hold one without synchronisation.
    ///
    /// Deliberately **not** coalesced across event batches, though it looked
    /// like the obvious companion fix to the one above. Eighty-four batches in
    /// a second do mean eighty-four rebuilds, but the overlay is a few hundred
    /// entries — thousands of appends and a sort of a two-hundred-element array,
    /// which is microseconds. Deferring it to the next turn of the loop would
    /// buy that back and make a created file asynchronously visible, so a
    /// caller reading straight after being told about one could miss it. The
    /// cost was the forty-five-shard search, not this.
    private func rebuildDelta(root: String) {
        guard let state = roots[root] else { return }
        guard !state.added.isEmpty else {
            roots[root]?.delta = nil
            return
        }
        var writer = FileCorpusWriter(reservingCapacity: state.added.count)
        for (path, info) in state.added {
            writer.add(
                relativePath: path, modified: info.modified,
                isDirectory: info.isDirectory
            )
        }
        roots[root]?.delta = writer.finish(root: root)
    }

    // MARK: - Refresh

    /// Rewalk one named shard.
    ///
    /// Named by the caller rather than chosen here. This used to pick the stalest
    /// shard itself, which meant the sweep asked the catalog what needed doing,
    /// decided it was worth doing, and then this asked again and was free to
    /// answer differently — two independent selections against a table either of
    /// them could have changed in between. It also left no way to express a
    /// policy about *which* shard, which is the whole of the sweep's job.
    @discardableResult
    public func refresh(shard: String, canonicalRoot root: String) async -> String? {
        guard let state = roots[root] else { return nil }
        let recorded = catalog?.shards(forRoot: root).first { $0.name == shard }
        log.record(
            "refresh",
            [
                ("shard", shard.isEmpty ? "(root)" : shard),
                (
                    "age",
                    recorded.map {
                        String(format: "%.0f", Date().timeIntervalSince($0.walkedAt))
                    } ?? "unknown"
                ),
                ("dirty", "\(recorded?.dirty ?? false)"),
            ]
        )
        await walk(
            shard: shard, canonical: root, root: state.url,
            skipping: effectiveSkipList(forCanonicalRoot: root),
            onProgress: { _ in }
        )
        return shard
    }

    /// Mark the shard a path belongs to as needing a rewalk. Used when the
    /// file system says it lost track — the only honest response is to redo
    /// that subtree.
    public func markSubtreeDirty(
        _ path: String, canonicalRoot root: String,
        reason: String = "must-scan-subdirs"
    ) {
        guard
            let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
        else { return }
        let components = relative.split(separator: "/")
        mark(components.first.map(String.init) ?? "", root: root, reason: reason)

        // A path with one component names something sitting directly in the
        // root, and that may be a file rather than a directory — in which case
        // it belongs to the root's own shard and not to one named after it. The
        // two are indistinguishable without a `stat`, which this path cannot
        // afford: it runs per event, on the main actor.
        //
        // So both are marked. Marking the named shard is free when no such shard
        // exists, and marking the root when the entry was in fact a directory
        // costs one rewalk of the root's own entries — seventy-odd of them,
        // because everything below is somebody else's shard. Cheaper than the
        // alternative, which was a mark that landed nowhere at all: a file
        // created directly in the root never invalidated anything.
        if components.count == 1 { mark("", root: root, reason: reason) }
    }

    private func mark(_ shard: String, root: String, reason: String) {
        // Already known. The condition is cheap to re-derive and the response
        // is not: a database write and a log line per repetition, on the main
        // thread, for a fact that has not changed.
        //
        // Except while the shard is being walked. A mark raised then describes a
        // change the walk in progress may already have passed, and the publish
        // that follows decides whether to keep the flag by comparing timestamps
        // — so the write has to happen for there to be a timestamp to compare.
        // Deduping here would answer a new event with an old walk.
        guard
            Self.shouldRecordMark(
                alreadyKnown: roots[root]?.dirtyShards.contains(shard) == true,
                isWalking: roots[root]?.walkingShards.contains(shard) == true
            )
        else { return }
        guard roots[root]?.unmarkableShards.contains(shard) != true else { return }

        // Remember the mark only once the catalog has taken it, for the reason
        // the dedupe above exists: a shard remembered as marked is not marked
        // again, so recording one that landed nowhere retires it permanently.
        guard catalog?.markDirty(root: root, name: shard) == true else {
            roots[root]?.unmarkableShards.insert(shard)
            log.record(
                "refresh",
                [
                    ("shard", shard.isEmpty ? "(root)" : shard),
                    ("event", "mark-lost"),
                    ("reason", reason),
                ]
            )
            return
        }
        roots[root]?.dirtyShards.insert(shard)

        log.record(
            "refresh",
            [
                ("shard", shard.isEmpty ? "(root)" : shard),
                ("event", "marked-dirty"),
                ("reason", reason),
            ]
        )
    }

    /// Take a batch of file-system events.
    ///
    /// Partitioned by asking the file system what is true *now* rather than by
    /// reading the event flags. A rename produces an old path that no longer
    /// exists and a new one that does, and this gets both right without having
    /// to reconstruct which event meant which.
    public func apply(touched: [String], rescan: [String], canonicalRoot root: String) {
        let classified = Self.classify(touched)
        apply(
            created: classified.created, removed: classified.removed,
            rescan: rescan, canonicalRoot: root
        )
    }

    /// Split paths into those that still exist and those that do not, reading
    /// what the existing ones are while asking.
    ///
    /// `nonisolated static` on purpose: this is the expensive half and none of
    /// it touches store state, so the watcher runs it on its own queue and hands
    /// over the answers. It used to run on the main actor, where a burst of nine
    /// hundred paths spent 213 ms in `stat` alone.
    public nonisolated static func classify(_ paths: [String])
        -> (created: [Appearance], removed: [String])
    {
        var created: [Appearance] = []
        var removed: [String] = []
        created.reserveCapacity(paths.count)
        for path in paths {
            var info = stat()
            if lstat(path, &info) == 0 {
                created.append(
                    Appearance(
                        path: path,
                        modified: Date(
                            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                        ),
                        isDirectory: info.st_mode & S_IFMT == S_IFDIR
                    )
                )
            } else {
                removed.append(path)
            }
        }
        return (created, removed)
    }

    public func apply(
        created: [Appearance], removed: [String], rescan: [String],
        canonicalRoot root: String
    ) {
        guard roots[root] != nil else { return }
        for path in rescan { markSubtreeDirty(path, canonicalRoot: root) }
        if !removed.isEmpty { noteRemoved(removed, canonicalRoot: root) }
        if !created.isEmpty { noteCreated(created, canonicalRoot: root) }
    }

    /// Apply a completed replay, then record how far the rest of the root got.
    ///
    /// One call so the ordering is not a caller's problem: the replay has to be
    /// applied first, because applying it is what marks the shards it mentioned,
    /// and marked shards are exactly the ones whose position must *not* move.
    public func applyReplay(
        created: [Appearance], removed: [String], rescan: [String],
        canonicalRoot root: String, horizon: UInt64
    ) {
        apply(
            created: created, removed: removed, rescan: rescan,
            canonicalRoot: root
        )
        advanceUntouchedShards(canonicalRoot: root, to: horizon)
    }

    /// Carry every shard the replay did not mention up to `horizon`.
    ///
    /// Dirty and walking shards are skipped, and that skip *is* the definition
    /// of "untouched" — applying the replay marked everything it mentioned, so
    /// what is left is what nothing happened to. A shard another application
    /// marked is skipped for the same reason, which is why the flag is read from
    /// the catalog row rather than only from memory.
    ///
    /// Without this a shard taken off the refresh rotation keeps the position it
    /// had when it was last walked, forever, and the root replays from it on
    /// every launch.
    func advanceUntouchedShards(canonicalRoot root: String, to horizon: UInt64) {
        guard let catalog, let state = roots[root] else { return }
        guard let uuid = FileIndexWatcher.volumeUUID(for: root) else { return }
        var advanced = 0
        for shard in catalog.shards(forRoot: root) {
            if shard.dirty { continue }
            if state.dirtyShards.contains(shard.name) { continue }
            if state.walkingShards.contains(shard.name) { continue }
            if let recorded = shard.eventsID, recorded >= horizon { continue }
            catalog.advanceEventPosition(
                root: root, name: shard.name, uuid: uuid, id: horizon
            )
            advanced += 1
        }
        guard advanced > 0 else { return }
        log.record(
            "watch",
            [
                ("event", "positions-advanced"),
                ("root", root),
                ("shards", "\(advanced)"),
                ("to", "\(horizon)"),
            ]
        )
    }

    // MARK: - Watching

    private var watchers: [String: FileIndexWatcher] = [:]

    /// Start watching a root, replaying whatever changed while nothing was
    /// running.
    public func watch(canonicalRoot root: String) {
        guard watchers[root] == nil else { return }
        let watcher = FileIndexWatcher(canonicalRoot: root)
        watchers[root] = watcher

        // Replay only if the volume is the one the position was recorded
        // against. A changed UUID means the event store was discarded, and a
        // position from the old one would silently replay the wrong history.
        let recorded = catalog?.shards(forRoot: root).compactMap { shard -> UInt64? in
            guard let uuid = shard.eventsUUID,
                uuid == FileIndexWatcher.volumeUUID(for: root)
            else { return nil }
            return shard.eventsID
        }
        watcher.start(since: recorded?.min())
    }

    public func stopWatching() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    /// Drop everything held in memory. For tests.
    public func forgetAll() {
        stopWatching()
        roots.removeAll()
        servedBy.removeAll()
    }
}
