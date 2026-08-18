import AppKit
import Combine
import Foundation

/// Presentation state for the file picker: whether it is up, what it is
/// offering, and what is selected.
///
/// Mounted by the host as a **top-aligned overlay on the area under its tab
/// strip**, not at the window root — the picker is anchored where an editor's
/// go-to-file panel is, so the field lands where the reader is already looking:
///
/// ```swift
/// @ObservedObject private var picker = FilePickerPresenter.shared
///
/// reader.overlay(alignment: .top) {
///     if picker.isPresented { FilePickerView().transition(.opacity) }
/// }
/// .animation(.easeInOut(duration: 0.12), value: picker.isPresented)
/// ```
///
/// Anchoring is safe from any surface because opening it selects the tab that
/// holds it first — see the host's own ⌘T path.
///
/// ### What is resolved when
///
/// The **root and the corpus** are asked for as the picker opens, because a
/// reader who has been working has moved the root since the last time and an
/// index built earlier would search the wrong tree. The **query** is live, and
/// filtering happens off the main actor.
///
/// Unlike the cheat sheet, nothing here is derived from focus, so there is no
/// snapshot to hold: the sheet freezes its rows because its own search field
/// makes a later read report "the user is typing". This has a search field too,
/// but what it shows is the query's answer rather than the host's state.
@MainActor
public final class FilePickerPresenter: ObservableObject {
    public static let shared = FilePickerPresenter()

    @Published public private(set) var isPresented = false

    /// What the reader has typed.
    @Published public var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshRows()
        }
    }

    @Published public private(set) var rows: [FilePickerItem] = []
    @Published public private(set) var selectedIndex = 0

    /// The root being browsed, shown above the field so a reader can see which
    /// tree they are searching before they wonder why a file is missing.
    @Published public private(set) var root: URL?

    /// True while the corpus is being walked, so the view can say so rather than
    /// looking like a picker with no matches.
    @Published public private(set) var isIndexing = false

    /// True when the walk stopped at its ceiling. Surfaced rather than swallowed:
    /// a reader ranking against half a tree should know that is what they are
    /// doing.
    @Published public private(set) var corpusWasTruncated = false

    /// How many files the walk actually indexed.
    ///
    /// Shown when the walk stopped short, because "part of the tree" is not
    /// something a reader can act on and a number is: it says how much was
    /// searched and implies what to do about it — narrow the root, or widen what
    /// is skipped.
    @Published public private(set) var indexedCount = 0

    // MARK: - What the host supplies

    /// Where to browse when the picker opens. Asked each time, so a root the
    /// host has since changed is picked up without this caching it.
    public var rootProvider: () -> URL? = { nil }

    /// Files closed in the current set, newest first — the first thing an empty
    /// query offers.
    public var closedProvider: () -> [ClosedTabStack.Entry] = { [] }

    /// Files opened earlier and still around, behind the closed ones.
    public var recentProvider: () -> [URL] = { [] }

    /// Directories the walk does not descend into.
    ///
    /// The host's answer rather than the engine's, because the right list
    /// depends on what the root *is*. `FileTreeIndex.defaultSkipList` is project
    /// noise, chosen for a root that is a repository; an application browsing a
    /// home directory needs more, and for a different reason — the walk caps and
    /// reports truncation, so one enormous directory spends the whole corpus
    /// before reaching anything a reader wanted.
    ///
    /// Defaults to the engine's list, so a host that has no opinion still gets
    /// the sensible answer.
    public var skipListProvider: () -> Set<String> = {
        FileTreeIndex.defaultSkipList
    }

    /// Open a file. The picker dismisses itself first, so a host that opens
    /// synchronously does not have to think about ordering.
    public var onOpen: (URL) -> Void = { _ in }

    /// Told when the reader re-roots, so the host can remember it. The picker
    /// does not own the root; it only asks for one and reports a change.
    public var onChangeRoot: (URL) -> Void = { _ in }

    // MARK: - Internals

    /// Shared with the cheat sheet and the inbox modal — see `ModalFocusCapture`
    /// for why each part of it is what it is.
    let focus = ModalFocusCapture()

    /// One tree, complete or still filling.
    ///
    /// A walk in progress writes into this as it goes, which is what lets a
    /// reader close the picker and reopen it further along instead of at zero.
    /// Held partials used to live outside the cache, so every open replaced the
    /// accumulated corpus with nothing and the count started over while the walk
    /// carried on unseen — the picker looked like it was restarting a walk that
    /// had in fact never stopped.
    private struct Corpus {
        var root: URL
        var items: [FileTreeIndex.Item]
        var wasTruncated: Bool
        /// When the walk finished. Nil while it is still running.
        var completedAt: Date?
    }

    /// Indexes by **canonical** root path.
    ///
    /// Canonical on both sides, which is not a formality: the walk resolves its
    /// root, so an index built for `/var/folders/…` reports itself as
    /// `/private/var/folders/…`. Compared against the unresolved path a host
    /// hands over, every open looked like a new root and threw the index away —
    /// the same trap `FilePaths` was written for, arriving one layer up.
    ///
    /// More than one, because re-rooting is a return trip: a reader narrows to a
    /// project, finds what they wanted, and comes back. Holding only the current
    /// tree made the way back as expensive as the way out.
    private var corpora: [String: Corpus] = [:]

    /// Roots being walked right now.
    ///
    /// **Without this, pressing ⌘T twice starts two walks of the same tree.** On
    /// a large root that is the difference between a picker that is slow once and
    /// one that is slow forever: every open added another full enumeration, none
    /// of them had landed, so every open looked like the first.
    private var walksInFlight: Set<String> = []

    /// How many indexed files are kept across all roots before the oldest
    /// finished tree is dropped.
    ///
    /// A budget in files rather than a count of trees, because the trees are not
    /// comparable: a home directory is half a million files and a project is
    /// twenty thousand. Counting trees would evict a home index to make room for
    /// something a hundredth its cost to rebuild, which is the wrong way round.
    ///
    /// Nothing is evicted while it is being walked, and never the tree on screen.
    private static let itemBudget = 750_000

    /// **A finished index is never re-walked.**
    ///
    /// There is no staleness window, and that is deliberate rather than pending:
    /// re-walking meant a reader who came back to a root watched a complete
    /// corpus be replaced by one counting up from zero — the restart this type
    /// spent three rounds removing, arriving through the door marked refresh. On
    /// a tree that takes tens of seconds and raises a permission prompt per
    /// protected directory, an unrequested re-walk is not a background detail.
    ///
    /// The cost is that a file created after the walk is not found until the
    /// process restarts. Noticing changes as they happen — and a way to ask for a
    /// refresh by hand — is its own effort, and the shape of this makes room for
    /// it: a corpus knows when it completed.

    /// Cancelled on every keystroke, so a slow filter over a large tree cannot
    /// land after the query it was answering has been typed past.
    private var filterTask: Task<Void, Never>?

    /// Internal so this package's tests can exercise an instance without
    /// mutating the singleton every other test shares. Hosts use `shared`.
    init() {}

    /// Whether the picker is claiming the keyboard.
    ///
    /// Read as a stand-down gate by every other local monitor that answers an
    /// unmodified key — and aggregated into `GalacticModals`, which is what
    /// those monitors actually consult.
    public static var isClaimingKeyboard: Bool { shared.isPresented }

    // MARK: - Opening and closing

    public func toggle() {
        isPresented ? dismiss() : present()
    }

    public func present() {
        guard !isPresented else { return }
        query = ""
        rows = []
        selectedIndex = 0
        root = rootProvider()
        focus.capture()
        isPresented = true
        focus.installEscape(
            standDown: { SheetAlert.isClaimingKeyboard },
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in self?.dismiss() }
        )
        // Offered before the walk starts, and not after it. What an empty query
        // shows — closed files, then recent ones — is the host's own history and
        // owes the corpus nothing, so making a reader watch a tree be indexed
        // before they can press Return on the file they just closed would be a
        // wait for no reason.
        refreshRows()
        buildIndex()
    }

    public func dismiss() {
        isPresented = false
        filterTask?.cancel()
        filterTask = nil
        focus.removeEscape()
    }

    /// Called by `FilePickerView` as it disappears, not by `dismiss` — see
    /// `ModalFocusCapture.restore` for why that ordering is the whole argument.
    func restoreFocus() {
        focus.restore()
    }

    // MARK: - Choosing

    public func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, selectedIndex + delta))
    }

    /// Open what is selected, or re-root when the query is a path.
    public func commit() {
        if let path = FilePickerRootInput.expandedPath(query) {
            changeRoot(to: URL(fileURLWithPath: path))
            return
        }
        guard rows.indices.contains(selectedIndex) else { return }
        let url = rows[selectedIndex].url
        dismiss()
        onOpen(url)
    }

    public func open(_ item: FilePickerItem) {
        dismiss()
        onOpen(item.url)
    }

    /// Put the reader on the path-typing route, from the header's folder chip.
    ///
    /// Prefills the field with the root's own path rather than opening a folder
    /// dialog, and that is the point: typing a path *is* how the root changes
    /// here, and the affordance that changes it should teach the mechanism
    /// instead of routing around it. The hint under the field takes over from
    /// there — it already says Return to browse and Tab to complete.
    public func beginRootChange() {
        let home = NSHomeDirectory()
        let path = root?.path ?? home
        query =
            (path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count) : path) + "/"
    }

    /// Extend a partly-typed path, the way a shell's Tab does.
    public func completePath() {
        guard let typed = FilePickerRootInput.expandedPath(query) else { return }
        let parent = (typed as NSString).deletingLastPathComponent
        let candidates = directories(under: URL(fileURLWithPath: parent))
        guard
            let completed = FilePickerRootInput.completion(
                for: query, directories: candidates
            )
        else { return }
        query = completed
    }

    private func changeRoot(to url: URL) {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else { return }

        root = url
        onChangeRoot(url)
        query = ""
        buildIndex()
    }

    private func directories(under url: URL) -> [String] {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else { return [] }
        return contents
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
            }
            .map(\.path)
    }

    // MARK: - The corpus

    /// Walk the root, reusing what is already held for it.
    ///
    /// **The index survives an open**, which a half-million-file ceiling makes
    /// mandatory rather than merely nice: walking a large tree takes seconds, and
    /// a reader pressing ⌘T is asking for a field to type into, not for a
    /// filesystem to be enumerated. So a held index for the same root is shown
    /// immediately and refreshed underneath — the reader ranks against what was
    /// there a moment ago while the walk catches up, and a file created since
    /// appears when it lands.
    ///
    /// A *different* root shows nothing rather than the tree just left — showing
    /// yesterday's tree under today's heading is worse than showing nothing,
    /// because nothing is obviously nothing — but the tree just left is kept,
    /// because re-rooting is usually a return trip.
    private func buildIndex() {
        guard let root else {
            rows = []
            return
        }

        let canonical = FilePaths.canonical(root)
        let held = corpora[canonical]

        // The rows are deliberately left alone when there is nothing held. What
        // is showing at this moment is the closed-and-recent list `present()`
        // offered before the walk started — the host's own history, which owes
        // the corpus nothing — and clearing it made a reader watch a tree be
        // indexed before they could reopen the file they just closed.
        //
        // Whatever is held is adopted as it stands, complete or partway. A
        // partial corpus is a usable one: it is the shallow end of the tree,
        // which is where the file they want usually is.
        corpusWasTruncated = held?.wasTruncated ?? false
        indexedCount = held?.items.count ?? 0

        let walking = walksInFlight.contains(canonical)
        // Reported while a walk is running, or while there is nothing at all to
        // rank against. A *refresh* behind a complete corpus is not reported —
        // that would put "indexing…" in the corner on every open.
        isIndexing = walking || held == nil

        // Already being walked. Two opens must not become two enumerations, and
        // the one in flight is still filling the corpus this just adopted.
        guard !walking else {
            refreshRows()
            return
        }

        // Already walked. Kept as it is, for as long as the process lives.
        if held?.completedAt != nil {
            refreshRows()
            return
        }

        // Starting over for this root: a fresh walk accumulates from nothing
        // rather than onto a corpus that may no longer describe the tree.
        corpora[canonical] = Corpus(
            root: root, items: [], wasTruncated: false, completedAt: nil
        )
        indexedCount = 0
        walksInFlight.insert(canonical)

        let target = root
        // Resolved here rather than inside the detached task, so the provider is
        // called on the main actor with the rest of the host's state.
        let skipping = skipListProvider()
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                // Batches are handed back as they are found, so a reader can
                // rank against a corpus that is still growing. On a large tree
                // the whole walk takes tens of seconds and the first useful
                // batch takes a fraction of one — waiting for the end of it is
                // what made the picker feel broken.
                //
                // Hopped to the main actor per batch rather than accumulated
                // here, because the point is that the rows update.
                FileTreeIndex.build(
                    root: target,
                    skipping: skipping,
                    onBatch: { batch in
                        Task { @MainActor [weak self] in
                            self?.absorb(batch, canonical: canonical)
                        }
                    }
                )
            }.value
            walksInFlight.remove(canonical)
            guard !Task.isCancelled else { return }

            // Kept whatever the reader is looking at now: a walk that finished
            // after they re-rooted is still the right answer for the tree it
            // walked, and throwing it away would make the trip back expensive
            // again. Keyed by the walk's own resolved root, which is canonical by
            // construction.
            complete(built, at: canonical)

            // Only shown if it is still the tree on screen.
            guard target.path == self.root?.path else { return }
            corpusWasTruncated = built.wasTruncated
            indexedCount = built.items.count
            isIndexing = false
            refreshRows()
        }
    }

    /// Drop finished trees, oldest first, until the budget is met.
    ///
    /// Partials are never dropped: one is being filled right now, and dropping it
    /// would restart the walk it belongs to — and never the tree just walked,
    /// which is the one the reader is most likely to ask for next.
    private func evictUntilWithinBudget(keeping: String) {
        func total() -> Int {
            corpora.values.reduce(0) { $0 + $1.items.count }
        }
        while total() > Self.itemBudget {
            let evictable = corpora.filter {
                $0.value.completedAt != nil && $0.key != keeping
            }
            guard
                let oldest = evictable.min(by: {
                    ($0.value.completedAt ?? .distantPast)
                        < ($1.value.completedAt ?? .distantPast)
                })
            else { return }
            corpora[oldest.key] = nil
        }
    }

    /// Take one batch from a walk in progress.
    ///
    /// Always written into the corpus for the tree it came from, whatever the
    /// reader is looking at now. A walk keeps going once started and keeps
    /// filling its own tree — so a reader who re-roots mid-walk and comes back
    /// finds it further along rather than starting again, and one who closes the
    /// picker and reopens it finds the same.
    ///
    /// Appended in place, which is why the items live here rather than inside a
    /// `FileTreeIndex`: handing the array to a struct per batch would copy the
    /// whole corpus on the next append, and at a hundred batches that is the
    /// walk's own cost again several times over.
    private func absorb(_ batch: [FileTreeIndex.Item], canonical: String) {
        guard corpora[canonical] != nil else { return }
        corpora[canonical]?.items.append(contentsOf: batch)

        // Only what the reader is looking at moves on screen.
        guard let root, FilePaths.canonical(root) == canonical else { return }
        indexedCount = corpora[canonical]?.items.count ?? 0
        refreshRows()
    }

    /// A walk finished. Mark its corpus complete and evict the oldest if needed.
    private func complete(_ built: FileTreeIndex, at canonical: String) {
        corpora[canonical] = Corpus(
            root: built.root,
            items: built.items,
            wasTruncated: built.wasTruncated,
            completedAt: Date()
        )
        evictUntilWithinBudget(keeping: canonical)
    }

    private func refreshRows() {
        filterTask?.cancel()

        // A path being typed is not a filter, so the corpus is not consulted
        // and the reader is not shown a list that ignores what they are doing.
        if FilePickerRootInput.isRootChange(query) {
            rows = []
            selectedIndex = 0
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rows = FilePickerRanking.emptyQueryList(
                closed: closedProvider(),
                recent: recentProvider(),
                root: root ?? URL(fileURLWithPath: NSHomeDirectory())
            )
            selectedIndex = 0
            return
        }

        guard let root,
            let items = corpora[FilePaths.canonical(root)]?.items,
            !items.isEmpty
        else { return }
        // Off the main actor, and cancelled per keystroke: a tree large enough
        // to be worth an index is large enough that scoring it would be felt.
        filterTask = Task {
            let matched = await Task.detached(priority: .userInitiated) {
                FilePickerRanking.matches(items, query: trimmed)
            }.value
            guard !Task.isCancelled else { return }
            rows = matched
            selectedIndex = 0
        }
    }
}
