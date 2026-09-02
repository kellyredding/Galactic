import Combine
import Foundation

/// The state behind a settings surface for the shared file index.
///
/// **There is no host protocol.** Every other shared surface in this package
/// needs one, because it describes something an application owns — a session, a
/// working directory, somewhere to send a review. The index is owned by none of
/// them: it is one set of files under `~/.galactic` that any application on the
/// machine reads and writes. So this asks the catalog directly, and two
/// applications showing this panel show the same thing without being wired to
/// each other.
///
/// **Nothing is cached between appearances.** Every published value here is
/// recomputed by `load()`, which is called when the surface appears and after
/// anything this model does. That is not laziness — another application may have
/// republished a shard or edited the skip list since the last look, and there is
/// no notification saying so. It also cannot be a timer: every catalog call is a
/// synchronous SQLite round-trip, so polling this would put disk reads on the
/// main actor for as long as the window stayed open.
@MainActor
public final class FileIndexSettingsModel: ObservableObject {

    /// Every root the index covers, whichever application adopted it.
    @Published public private(set) var roots: [FileIndexRootStatus] = []
    /// Directory names excluded from every walk, whichever tree it is in.
    @Published public private(set) var skipped: [String] = []
    /// Shards with a walk in flight, so their rows can say so.
    @Published public private(set) var working: Set<String> = []
    @Published public private(set) var hasLoaded = false

    /// Which root's folder list is on screen. The skip list is not scoped by it.
    @Published public var selectedRoot: String?

    private var catalog: FileIndexCatalog?

    public init() {}

    /// Where the index lives, for a surface that wants to say so.
    public var indexLocation: URL { FileIndexPaths.root }

    public var selectedStatus: FileIndexRootStatus? {
        roots.first { $0.root == selectedRoot }
    }

    /// Files across every tree the index covers, which is what "the index"
    /// means — the per-root figure is a detail of one row.
    public var totalEntries: Int { roots.reduce(0) { $0 + $1.totalEntries } }

    /// Names in the list that only take effect under the home directory.
    public var homeOnlySkips: Set<String> { FileCorpusBuilder.homeOnlyNames }

    // MARK: - Reading

    public func load() {
        if catalog == nil { catalog = FileIndexCatalog() }
        guard let catalog else { return }
        roots = catalog.roots().sorted().map { root in
            FileIndexStatusReport.report(
                for: catalog.shards(forRoot: root), root: root
            )
        }
        if selectedRoot == nil || !roots.contains(where: { $0.root == selectedRoot }) {
            selectedRoot = roots.first?.root
        }
        skipped = Self.skipList(catalog: catalog).sorted()
        hasLoaded = true
    }

    /// The list every walk uses, whatever tree it is walking.
    ///
    /// The built-in base still varies by root — three names apply only under the
    /// home directory, because `Library` there is noise and `Library` in a
    /// checkout is source. Everything a person added or removed applies
    /// everywhere, so what is shown is the union: the widest set the index will
    /// ever skip, with the conditional entries identifiable via
    /// `FileCorpusBuilder.homeOnlyNames`.
    ///
    /// Not actor-bound, because nothing about it is: the base is a pure function
    /// and the catalog serialises itself.
    public nonisolated static func skipList(
        catalog: FileIndexCatalog
    ) -> Set<String> {
        var list = FileCorpusBuilder.homeSkipList
        let delta = catalog.skipListDelta()
        list.formUnion(delta.added)
        list.subtract(delta.removed)
        return list
    }

    /// What a walk of one specific root would use.
    ///
    /// The same composition the walk performs, for a surface that needs to be
    /// exact about one tree rather than describe the whole index.
    public nonisolated static func effectiveSkipList(
        forRoot root: String, catalog: FileIndexCatalog
    ) -> Set<String> {
        var list = FileCorpusBuilder.skipList(
            forRoot: URL(fileURLWithPath: root)
        )
        let delta = catalog.skipListDelta()
        list.formUnion(delta.added)
        list.subtract(delta.removed)
        return list
    }

    /// Which shards, across every tree, a change to `name` would invalidate.
    ///
    /// Answered before the edit so a surface can say what it will cost. An empty
    /// answer means no shard anywhere ever met the name, so nothing needs
    /// rewalking — which is the common case and the reason editing this list is
    /// cheap.
    public func shardsAffected(byChanging name: String) -> [(root: String, shard: String)] {
        catalog?.shardsEncountering(skip: name) ?? []
    }

    // MARK: - Acting

    /// Walk one shard now.
    ///
    /// Immediate rather than queued, because this only ever runs from a person
    /// pressing something. A consent dialog raised by the walk therefore lands
    /// while they are still looking at the row they pressed, which is the only
    /// context in which it explains itself.
    public func refresh(shard: String) async {
        guard let root = selectedRoot else { return }
        await refresh(shard: shard, in: root)
    }

    public func refresh(shard: String, in root: String) async {
        working.insert(shard)
        defer {
            working.remove(shard)
            load()
        }
        await FileCorpusStore.shared.refresh(shard: shard, canonicalRoot: root)
    }

    /// Refresh every shard the index is not currently serving completely.
    public func refreshAllNeedingAttention() async {
        guard let status = selectedStatus else { return }
        for shard in status.needingAttention {
            await refresh(shard: shard.name)
        }
    }

    /// Start skipping `name`, everywhere.
    ///
    /// A top-level directory already in the index has to be removed rather than
    /// marked stale, because a rewalk would rebuild it — the skip list governs
    /// what a walk descends into, never whether a shard exists. That has to
    /// happen for every tree, since one name may name a top-level directory in
    /// several of them.
    public func skip(_ name: String) async {
        guard let catalog else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        catalog.setSkipListEntry(name: trimmed, skipped: true)
        for root in catalog.roots() {
            FileCorpusStore.shared.prune(shard: trimmed, canonicalRoot: root)
        }
        await rewalkShardsMeeting(trimmed, catalog: catalog)
        load()
    }

    /// Stop skipping `name`, and walk exactly what that changes.
    public func unskip(_ name: String) async {
        guard let catalog else { return }
        // Cleared rather than stored as false when no built-in list carries it,
        // so a name that was only ever an addition stops occupying a row
        // claiming a decision was made against the default.
        if FileCorpusBuilder.homeSkipList.contains(name) {
            catalog.setSkipListEntry(name: name, skipped: false)
        } else {
            catalog.clearSkipListEntry(name: name)
        }
        await rewalkShardsMeeting(name, catalog: catalog)
        load()
    }

    private func rewalkShardsMeeting(
        _ name: String, catalog: FileIndexCatalog
    ) async {
        for hit in catalog.shardsEncountering(skip: name) {
            catalog.markDirty(root: hit.root, name: hit.shard)
            await refresh(shard: hit.shard, in: hit.root)
        }
    }

    // MARK: - Roots

    /// Stop indexing a tree.
    ///
    /// The escape hatch for a root adopted by browsing to it once. Nothing else
    /// removes one: a root is retired only when a wider root starts answering
    /// for it, so a volume visited a single time would otherwise be walked,
    /// watched and swept for as long as the index exists.
    public func stopIndexing(root: String) {
        FileCorpusStore.shared.stopIndexing(canonicalRoot: root)
        if selectedRoot == root { selectedRoot = nil }
        load()
    }
}
