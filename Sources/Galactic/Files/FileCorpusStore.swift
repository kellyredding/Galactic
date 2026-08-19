import Foundation

/// Every corpus this process holds, and the only thing that walks a tree.
///
/// ### Why ownership left the presenter
///
/// The presenter is per-modal and the corpus is not. Assist Ant hides that —
/// one window, one picker, one root — but Galaxy is a session per tab, each
/// with its own working directory, and per-presenter corpora there would mean
/// several copies of the same tree resident at once and several walks
/// competing to build them.
///
/// ### What is not here any more
///
/// The eviction budget is gone rather than moved. It existed to ration an
/// index that cost 56 MB per root; at 13 MB of bytes for four hundred thousand
/// entries there is nothing to ration, and a budget is a number somebody has
/// to justify. Nothing is dropped, and a root that was walked stays walked for
/// the life of the process.
@MainActor
public final class FileCorpusStore {

    public static let shared = FileCorpusStore()

    /// Finished corpora, by canonical root path.
    private var held: [String: FileCorpus] = [:]
    /// Roots being walked right now.
    ///
    /// **Without this, pressing ⌘T twice starts two walks of the same tree**,
    /// and on a large root that is the difference between slow once and slow
    /// forever.
    private var walking: Set<String> = []
    /// Entries seen so far by a walk in flight, so the picker can show a
    /// climbing number rather than a bare "indexing…", which is
    /// indistinguishable from a hang.
    private var progress: [String: Int] = [:]

    init() {}

    public func corpus(forCanonicalRoot root: String) -> FileCorpus? {
        held[root]
    }

    public func isWalking(_ root: String) -> Bool { walking.contains(root) }

    /// How many entries are known for a root: the finished count, or the
    /// running one while a walk is in flight.
    public func indexedCount(forCanonicalRoot root: String) -> Int {
        held[root]?.entryCount ?? progress[root] ?? 0
    }

    /// Ensure a root is indexed, walking it if it is not.
    ///
    /// `onProgress` is a *count* and nothing else. The index this replaces
    /// handed back batches of files, and each batch drove a full re-rank —
    /// which is how a single walk became sixty-three overlapping ranking
    /// passes and pegged fifteen cores. Progress moves a number; only the
    /// finish, or a keystroke, moves rows.
    public func index(
        root: URL,
        skipping skipList: Set<String>,
        onProgress: @escaping (Int) -> Void = { _ in },
        onFinished: @escaping () -> Void = {}
    ) {
        let canonical = FilePaths.canonical(root)
        if held[canonical] != nil {
            onFinished()
            return
        }
        guard !walking.contains(canonical) else { return }

        walking.insert(canonical)
        progress[canonical] = 0

        Task {
            // `.utility`, not `.userInitiated`. The walk is background work
            // with a visible counter; at user-initiated it competed for cores
            // with the interface it was blocking.
            let corpus = await Task.detached(priority: .utility) {
                FileCorpusBuilder.build(
                    root: root,
                    skipping: skipList,
                    onProgress: { count in
                        Task { @MainActor in
                            FileCorpusStore.shared.report(count, for: canonical)
                            onProgress(count)
                        }
                    }
                )
            }.value

            held[canonical] = corpus
            walking.remove(canonical)
            progress[canonical] = nil
            onFinished()
        }
    }

    private func report(_ count: Int, for root: String) {
        guard walking.contains(root) else { return }
        progress[root] = count
    }

    /// Drop everything. For tests, and for a future explicit refresh.
    public func forgetAll() {
        held.removeAll()
        progress.removeAll()
    }
}
