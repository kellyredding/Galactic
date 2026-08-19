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
/// The shards are rewritten on a slow rotation, which folds the other two back
/// in and is also the backstop for events the file system dropped.
@MainActor
public final class FileCorpusStore {

    public static let shared = FileCorpusStore()

    private struct RootState {
        var url: URL
        var skipList: Set<String>
        /// Shard name → its corpus. The empty name is the root's own entries.
        var shards: [String: FileCorpus] = [:]
        /// Shard name → bitset of entries deleted since it was written.
        var removed: [String: [UInt64]] = [:]
        /// Files seen created since the last walk, by relative path.
        var added: [String: (modified: Date?, isDirectory: Bool)] = [:]
        /// `added`, encoded as a corpus so the matcher can scan it unchanged.
        var delta: FileCorpus?
        var walkingShards: Set<String> = []
        var progress = 0
        var isLoaded = false
    }

    private var roots: [String: RootState] = [:]

    /// A root being browsed → the indexed root that already contains it.
    ///
    /// Sorted order makes a subtree a contiguous range, which is what was
    /// supposed to make nesting free. Without this the store keyed everything
    /// by exact path and re-walked `~/projects` in full while an index of `~`
    /// containing every one of those entries sat beside it.
    private var servedBy: [String: String] = [:]
    /// Opened per use rather than held.
    ///
    /// A held connection binds to whatever `~/.galactic` resolved to when this
    /// singleton was first touched, which is before a host has necessarily
    /// created it — and permanently, so a test pointing the index elsewhere
    /// would still be writing to the first location it ever saw. Opening is
    /// cheap and these calls are rare: publishing a shard, loading at launch,
    /// and one rotation tick a minute.
    private var catalog: FileIndexCatalog? { FileIndexCatalog() }
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
                    && roots[candidate]?.shards.isEmpty == false
            }
            .max { $0.count < $1.count }
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
    /// rotation that is not reaching them.
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
    public func index(
        root: URL,
        skipping skipList: Set<String>,
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
            onFinished()
            return
        }
        if roots[canonical] == nil {
            roots[canonical] = RootState(url: root, skipList: skipList)
        }
        guard roots[canonical]?.isLoaded != true else {
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
        for shard in catalog.shards(forRoot: canonical) where !shard.dirty {
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
        }
        roots[canonical]?.shards = mapped
        return mapped
    }

    private func walkMissingShards(
        canonical: String,
        onProgress: @escaping (Int) -> Void,
        onFinished: @escaping () -> Void
    ) async {
        guard let state = roots[canonical] else { return }
        let root = state.url
        let skipList = state.skipList

        // The root's own shard first: it is what names all the others.
        if state.shards[""] == nil {
            await walk(shard: "", canonical: canonical, root: root, skipping: skipList, onProgress: onProgress)
        }
        guard let rootShard = roots[canonical]?.shards[""] else {
            onFinished()
            return
        }
        var names: [String] = []
        for index in 0..<rootShard.entryCount where rootShard.isDirectory(at: index) {
            names.append(rootShard.relativePath(at: index))
        }

        for name in names where roots[canonical]?.shards[name] == nil {
            await walk(shard: name, canonical: canonical, root: root, skipping: skipList, onProgress: onProgress)
        }
        // Watching and rotating start only once there is an index to keep
        // fresh. Before that there is nothing for an event to update, and a
        // replay would be answering questions about a corpus that does not
        // exist yet.
        watch(canonicalRoot: canonical)
        FileIndexRefreshRotation.shared.add(canonicalRoot: canonical)

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

        let corpus = await Task.detached(priority: .utility) {
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

        roots[canonical]?.shards[shard] = corpus
        roots[canonical]?.removed[shard] = nil
        roots[canonical]?.walkingShards.remove(shard)
        dropOverlayEntries(under: shard, canonical: canonical)

        let elapsed = Date().timeIntervalSince(started)
        publish(corpus, shard: shard, canonical: canonical)

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
    private func publish(_ corpus: FileCorpus, shard: String, canonical: String) {
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
            log.record(
                "publish",
                [("shard", shard), ("result", "deferred"), ("reason", "another-writer")]
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
                entryCount: corpus.entryCount,
                eventsUUID: FileIndexWatcher.volumeUUID(for: canonical),
                eventsID: FileIndexWatcher.currentEventID()
            )
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
    public func noteCreated(_ paths: [String], canonicalRoot root: String) {
        guard var state = roots[root] else { return }
        var changed = 0
        for path in paths {
            guard
                let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
            else { continue }
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
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
            guard Self.isIndexable(relative, skipping: state.skipList) else {
                continue
            }
            if clearRemoval(of: relative, in: &state) {
                changed += 1
                continue
            }
            if state.added[relative] == nil { changed += 1 }
            state.added[relative] = (
                Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                isDirectory
            )
        }
        roots[root] = state
        if changed > 0 {
            rebuildDelta(root: root)
            log.record(
                "watch",
                [("event", "created"), ("count", "\(changed)"), ("pending", "\(roots[root]?.added.count ?? 0)")]
            )
        }
    }

    /// Record files that went away, by setting a bit rather than rewriting a
    /// shard.
    public func noteRemoved(_ paths: [String], canonicalRoot root: String) {
        guard var state = roots[root] else { return }
        var changed = 0
        for path in paths {
            guard
                let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
            else { continue }
            if state.added.removeValue(forKey: relative) != nil { changed += 1 }
            if markRemoved(relative, in: &state) { changed += 1 }
        }
        roots[root] = state
        if changed > 0 {
            rebuildDelta(root: root)
            log.record(
                "watch", [("event", "removed"), ("count", "\(changed)")]
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

    private func markRemoved(_ relative: String, in state: inout RootState) -> Bool {
        let needle = Array(relative.utf8)
        for (name, corpus) in state.shards {
            let index = corpus.firstIndex(atOrAfter: needle)
            guard index < corpus.entryCount,
                corpus.relativePath(at: index) == relative
            else { continue }
            var bits =
                state.removed[name]
                ?? [UInt64](repeating: 0, count: (corpus.entryCount + 63) / 64)
            bits[index >> 6] |= 1 << UInt64(index & 63)
            state.removed[name] = bits
            return true
        }
        return false
    }

    /// Un-delete a path a shard already holds.
    ///
    /// Returns whether a shard covers this path, which is what tells the
    /// caller not to add it to the delta as well.
    @discardableResult
    private func clearRemoval(of relative: String, in state: inout RootState)
        -> Bool
    {
        let needle = Array(relative.utf8)
        for (name, corpus) in state.shards {
            let index = corpus.firstIndex(atOrAfter: needle)
            guard index < corpus.entryCount,
                corpus.relativePath(at: index) == relative
            else { continue }
            if state.removed[name] != nil {
                state.removed[name]?[index >> 6] &= ~(1 << UInt64(index & 63))
            }
            return true
        }
        return false
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
    /// Rebuilt whole rather than appended to, because it is small by
    /// construction — the shards absorb it on every rotation — and a corpus is
    /// immutable once built, which is what lets a scan hold one without
    /// synchronisation.
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

    /// Rewalk the shard that has gone longest without being walked.
    ///
    /// The backstop for events the file system dropped, which it will: the
    /// kernel discards a non-Apple watcher's whole queue under load, and a
    /// large checkout is exactly that load. Oldest first, one at a time, so
    /// nothing is ever much more than a rotation stale and no single moment
    /// costs a whole tree.
    @discardableResult
    public func refreshStalestShard(canonicalRoot root: String) async -> String? {
        guard let state = roots[root] else { return nil }
        guard let stalest = catalog?.stalestShard(forRoot: root) else { return nil }
        log.record(
            "refresh",
            [
                ("shard", stalest.name.isEmpty ? "(root)" : stalest.name),
                ("age", String(format: "%.0f", Date().timeIntervalSince(stalest.walkedAt))),
                ("dirty", "\(stalest.dirty)"),
            ]
        )
        await walk(
            shard: stalest.name, canonical: root, root: state.url,
            skipping: state.skipList, onProgress: { _ in }
        )
        return stalest.name
    }

    /// Mark the shard a path belongs to as needing a rewalk. Used when the
    /// file system says it lost track — the only honest response is to redo
    /// that subtree.
    public func markSubtreeDirty(_ path: String, canonicalRoot root: String) {
        guard
            let relative = FilePaths.relativeEntry(of: path, underCanonical: root)
        else { return }
        let shard = relative.split(separator: "/").first.map(String.init) ?? ""
        catalog?.markDirty(root: root, name: shard)
        log.record("refresh", [("shard", shard), ("event", "marked-dirty")])
    }

    /// Take a batch of file-system events.
    ///
    /// Partitioned by asking the file system what is true *now* rather than by
    /// reading the event flags. A rename produces an old path that no longer
    /// exists and a new one that does, and this gets both right without having
    /// to reconstruct which event meant which.
    public func apply(touched: [String], rescan: [String], canonicalRoot root: String) {
        guard roots[root] != nil else { return }
        for path in rescan { markSubtreeDirty(path, canonicalRoot: root) }

        var created: [String] = []
        var removed: [String] = []
        for path in touched {
            var info = stat()
            if lstat(path, &info) == 0 {
                created.append(path)
            } else {
                removed.append(path)
            }
        }
        if !removed.isEmpty { noteRemoved(removed, canonicalRoot: root) }
        if !created.isEmpty { noteCreated(created, canonicalRoot: root) }
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
