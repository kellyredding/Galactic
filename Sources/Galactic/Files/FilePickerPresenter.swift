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
            // Only the mode on screen is rebuilt. Both would mean two corpus
            // scans per keystroke to show one of them.
            refreshApplicableRows()
        }
    }

    @Published public private(set) var rows: [FilePickerItem] = []
    @Published public private(set) var selectedIndex = 0

    /// Which of the two ways of finding a file is on screen.
    ///
    /// Always `.search` when the picker opens. ⌘T is the fast path and the one
    /// there is muscle memory for; a picker that reopened in whatever mode was
    /// last used would make one keystroke mean two things.
    @Published public private(set) var mode: FilePickerMode = .search

    @Published public private(set) var treeRows: [FileTreeOutline.Row] = []
    @Published public private(set) var treeSelectedIndex = 0

    /// A row to bring to the top of a list, once it exists.
    ///
    /// Carries which list it is for, because both tabs remember their own place
    /// and only one of them is on screen to act on it. A row id rather than an
    /// offset: both lists fill in after the fact — the tree as directories are
    /// read, the ranked list when the scan lands — so an offset into a list
    /// still being built points at whatever happens to be there.
    public struct ScrollTarget: Equatable {
        public let mode: FilePickerMode
        public let id: String
    }

    @Published public private(set) var scrollTarget: ScrollTarget?

    /// The row currently at the top of each list.
    ///
    /// **Deliberately not `@Published`.** These are written on every scroll
    /// frame, and publishing them would invalidate the view once per frame to
    /// record something only a later reopen ever reads.
    private var treeScrollTop: String?
    private var searchScrollTop: String?
    private var pendingTreeScroll: String?
    private var pendingSearchScroll: String?

    private var outline = FileTreeOutline()

    /// Directory contents already read, by absolute path.
    ///
    /// Expanding is user-initiated, so this is filled on demand rather than
    /// ahead of time, and a directory is read once per opening of the picker.
    /// Dropped with the rest of the browse state on open, because a folder
    /// created since the last look should appear.
    private var childCache: [String: [FileTreeOutline.Entry]] = [:]
    private var loadingChildren: Set<String> = []

    /// Which owner this panel was opened for.
    ///
    /// Captured at `present()` rather than asked again at `dismiss()`, because
    /// a host is free to switch file sets while the panel is up: asking a second
    /// time files one set's tree under another set's key, and the wrong tree
    /// then comes back for both. The searcher beside this one already latches
    /// its owner for the same reason.
    private var presentedOwner: String?

    /// What the picker was left showing, per file set.
    ///
    /// The picker is one object serving every set, so this is what makes it
    /// behave like one picker per set: reopening it is returning to a place
    /// rather than starting over. Held here rather than on `FileSet` because it
    /// is presentation state — where a reader had got to in a panel — and a set
    /// is a list of open files.
    ///
    /// In memory only. Surviving a relaunch would mean persisting an expansion
    /// set whose folders may since have gone, and the reader has no way to see
    /// why the tree looks the way it does after a restart.
    private var saved: [String: SessionState] = [:]

    private struct SessionState {
        var mode: FilePickerMode
        var query: String
        var expanded: Set<String>
        /// By path, not by index. A restored tree is not guaranteed to be the
        /// same shape — a folder may have gone — and an index into a list that
        /// changed points at whatever moved into that slot.
        var selectedPath: String?
        /// Where the tree was scrolled to, which is not the same question as
        /// what was selected: a reader scrolls a long way with the wheel
        /// without moving the selection at all, and coming back to the
        /// selection would undo the scroll they are asking to keep.
        var treeScrollTop: String?
        var searchScrollTop: String?
        var children: [String: [FileTreeOutline.Entry]]
        /// The root it all describes. Every path above is relative to it, so a
        /// host that has re-rooted since invalidates the whole thing.
        var root: String
    }

    /// The root being browsed, editable in the field above the query so a reader
    /// can both see which tree they are searching and change it.
    @Published public private(set) var root: URL?

    /// The root field, shared with the searcher so the two panels cannot come to
    /// disagree about what Tab does in one.
    ///
    /// Observed by the field's own view rather than forwarded through here: the
    /// view is the only thing that reads it, so a second hop would invalidate
    /// the whole card to redraw one row.
    public let rootFieldModel = FileRootFieldModel()

    /// What a relative path is relative to: the route shown above the field.
    ///
    /// The same thing the reader is looking at, deliberately — `..` has to go
    /// up from where the picker *says* they are, or the answer is somewhere
    /// they cannot see.
    private var route: String? { root?.path }

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

    /// Open a file. The picker dismisses itself first, so a host that opens
    /// synchronously does not have to think about ordering.
    public var onOpen: (URL) -> Void = { _ in }

    /// Told when the reader re-roots, so the host can remember it. The picker
    /// does not own the root; it only asks for one and reports a change.
    public var onChangeRoot: (URL) -> Void = { _ in }

    /// Which file set the picker is being opened for.
    ///
    /// `FileSet.ownerID` — a session id in Galaxy, a constant in Assist Ant.
    /// What it keys is the state below: reopening the picker returns to what it
    /// was left showing, and one session's tree is not another's.
    public var ownerProvider: () -> String = { "" }

    // MARK: - Internals

    /// Shared with the cheat sheet and the inbox modal — see `ModalFocusCapture`
    /// for why each part of it is what it is.
    let focus = ModalFocusCapture()

    /// Cancelled on every keystroke, so a slow filter over a large tree cannot
    /// land after the query it was answering has been typed past.
    private var filterTask: Task<Void, Never>?

    /// The flag the *running* scan reads.
    ///
    /// Cancelling a `Task` stops whoever is awaiting its result and nothing
    /// else, which is exactly how sixty-three ranking passes came to run at
    /// once: each had been told to stop, and none of them was listening.
    private var filterCancellation = FileMatcher.Cancellation()

    /// Internal so this package's tests can exercise an instance without
    /// mutating the singleton every other test shares. Hosts use `shared`.
    init() {
        rootFieldModel.route = { [weak self] in self?.root }
        rootFieldModel.onCommit = { [weak self] url in self?.changeRoot(to: url) }
    }

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
        // One card under the tab strip at a time — see
        // `FileSearchPresenter.present()`, which says the same in the other
        // direction.
        FileSearchPresenter.shared.dismiss()
        rows = []
        resetSelection()
        // Dropped on open rather than on a timer: a folder created since the
        // last look should appear, and opening is the moment a reader asks.
        // Dropped whatever else is restored: this is the completion aid for a
        // path being typed, and a folder created since the last look should
        // appear in it.
        root = rootProvider()
        presentedOwner = ownerProvider()
        rootFieldModel.reset()
        restoreState()
        focus.arm(
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in self?.dismiss() }
        )
        isPresented = true
        // Offered before the walk starts, and not after it. What an empty query
        // shows — closed files, then recent ones — is the host's own history and
        // owes the corpus nothing, so making a reader watch a tree be indexed
        // before they can press Return on the file they just closed would be a
        // wait for no reason.
        // **Mode-aware, and that is not a tidiness point.** `refreshRows` begins
        // by cancelling the running scan, so calling it unconditionally here
        // killed the scan that a restored Browse filter had just started — and
        // the tree was left holding the unfiltered rows from the pass before it,
        // with the query still in the field claiming to have been applied.
        refreshApplicableRows()
        buildIndex()
    }

    public func dismiss() {
        rememberState()
        isPresented = false
        filterTask?.cancel()
        filterTask = nil
        focus.disarm()
    }

    private func rememberState() {
        guard let root, let owner = presentedOwner else { return }
        let selected = treeRows.indices.contains(treeSelectedIndex)
            ? treeRows[treeSelectedIndex].path : nil
        saved[owner] = SessionState(
            mode: mode,
            query: query,
            expanded: outline.expandedByReader,
            selectedPath: selected,
            treeScrollTop: treeScrollTop,
            searchScrollTop: searchScrollTop,
            children: childCache,
            root: FilePaths.canonical(root)
        )
    }

    /// Put the picker back where it was left, or start it fresh.
    ///
    /// The **root decides** whether there is anything to restore. Every path in
    /// a saved tree is under the root it was saved against, so a host that has
    /// re-rooted since is offering a tree of somewhere else — and restoring it
    /// would show a reader folders that are not in the tree they are looking at.
    private func restoreState() {
        let canonical = root.map { FilePaths.canonical($0) }
        guard let owner = presentedOwner, let state = saved[owner],
            state.root == canonical
        else {
            mode = .search
            query = ""
            resetBrowseState()
            return
        }
        mode = state.mode
        childCache = state.children
        loadingChildren = []
        outline = FileTreeOutline(expandedByReader: state.expanded)
        pendingSelection = state.selectedPath
        pendingTreeScroll = state.treeScrollTop ?? state.selectedPath
        pendingSearchScroll = state.searchScrollTop
        query = state.query
    }

    /// The row to land on once the tree has been rebuilt, by path.
    private var pendingSelection: String?

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

    /// Back to the first row.
    private func resetSelection() {
        selectedIndex = 0
        claimSearchScroll()
    }

    /// Ask to scroll the ranked list back, the first pass its row appears on.
    ///
    /// Later than the tree's equivalent by necessity: these rows are the answer
    /// to a scan that runs off the main actor, so on the pass that opens the
    /// picker there is nothing yet for a remembered row to be found in.
    private func claimSearchScroll() {
        guard let wanted = pendingSearchScroll,
            rows.contains(where: { $0.id == wanted })
        else { return }
        pendingSearchScroll = nil
        scrollTarget = ScrollTarget(mode: .search, id: wanted)
    }

    /// Act on the selection.
    ///
    /// **This was four rules in a fixed order until the root field existed.**
    /// One field did two jobs, so Return had to tell apart the folder you picked
    /// from the folder you named, and a path ending in a separator had to beat
    /// the highlighted first match. None of that was incidental complexity —
    /// each rule answered a real case — but every one of those cases was a
    /// consequence of asking one field what it was being used for. The field
    /// above answers paths now, so this answers rows.
    public func commit() {
        guard rows.indices.contains(selectedIndex) else { return }
        activate(rows[selectedIndex])
    }

    public func open(_ item: FilePickerItem) {
        activate(item)
    }

    /// What a row does, in one place — so a click and Return cannot diverge.
    ///
    /// A folder is browsed into and the picker **stays open**: re-rooting is
    /// what someone does in order to then find a file there, and dismissing
    /// would make them reopen it to do the thing they re-rooted for.
    private func activate(_ item: FilePickerItem) {
        guard item.source != .folder else {
            changeRoot(to: item.url)
            return
        }
        dismiss()
        onOpen(item.url)
    }

    // MARK: - Browsing

    public func selectMode(_ next: FilePickerMode) {
        guard next != mode else { return }
        mode = next
        // The outgoing mode's scan is poisoned on the way out, the same way a
        // keystroke poisons the previous one: switching tabs is as much a
        // change of question as typing is.
        filterTask?.cancel()
        filterCancellation.cancel()
        refreshApplicableRows()
    }

    /// Move to the other tab. Two modes, so there is only ever one other.
    public func toggleMode() {
        selectMode(mode == .search ? .browse : .search)
    }

    private func resetBrowseState() {
        childCache = [:]
        loadingChildren = []
        treeRows = []
        treeSelectedIndex = 0
        treeScrollTop = nil
        pendingTreeScroll = nil
        scrollTarget = nil
        // The root opens with the picker. A tree whose only row is its own root,
        // collapsed, offers nothing to browse and one keystroke of ceremony
        // before it does.
        outline = FileTreeOutline(
            expandedByReader: root.map { [FilePaths.canonical($0)] } ?? []
        )
    }

    /// Rebuild the tree from whichever source the query calls for.
    ///
    /// A filter is answered by the **index** and browsing by the **disk**, and
    /// they are never both answering — see `FileTreeOutline` for why that means
    /// they never have to be reconciled.
    private func refreshTree() {
        guard let root else {
            treeRows = []
            return
        }
        let canonical = FilePaths.canonical(root)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            treeRows = outline.rows(root: canonical) { [weak self] path in
                self?.children(of: path) ?? []
            }
            clampTreeSelection()
            return
        }

        let slices = FileCorpusStore.shared.slices(forCanonicalRoot: canonical)
        guard !slices.isEmpty else {
            treeRows = []
            return
        }

        filterCancellation.cancel()
        let cancellation = FileMatcher.Cancellation()
        filterCancellation = cancellation
        filterTask = Task {
            let matched = await Task.detached(priority: .userInitiated) {
                FilePickerRanking.matches(
                    slices, query: trimmed, relativeTo: canonical,
                    cancellation: cancellation
                )
            }.value
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            treeRows = outline.rows(
                root: canonical,
                matching: matched.map {
                    // `relativePath` is what the offsets index, which is the
                    // same string the ranked list highlights — so one match is
                    // highlighted identically whichever tab shows it.
                    FileTreeOutline.Match(
                        path: $0.url.path, highlighted: $0.matchedOffsets
                    )
                }
            )
            clampTreeSelection()
        }
    }

    /// A directory's entries, read once and remembered.
    ///
    /// Answers immediately from the cache and starts a read when there is
    /// nothing cached, so expanding never blocks the main actor on a `readdir`
    /// — which is the shape of the beach ball this whole feature was once fixed
    /// for, where `stat` accounted for 213 ms of a 218 ms burst.
    private func children(of path: String) -> [FileTreeOutline.Entry] {
        if let cached = childCache[path] { return cached }
        guard !loadingChildren.contains(path) else { return [] }
        loadingChildren.insert(path)
        Task { @MainActor in
            let entries = await Task.detached(priority: .userInitiated) {
                // **Sorted here, off the main actor.** The flatten used to do
                // it, which meant re-sorting the same unchanged names on every
                // refresh — measured at 194 ms per draw for a 2,392-entry
                // directory. A directory's contents do not change between
                // draws, so this belongs with the read.
                FileDirectoryReader.childEntries(of: path)
                    .sorted(by: FileTreeOutline.precedes)
            }.value
            self.loadingChildren.remove(path)
            self.childCache[path] = entries
            // Only the browsing tree reads this cache; a filter's rows come
            // from the index and would be rebuilt from nothing.
            if self.mode == .browse { self.refreshTree() }
        }
        return []
    }

    private func clampTreeSelection() {
        guard !treeRows.isEmpty else {
            treeSelectedIndex = 0
            return
        }
        // A remembered row is claimed the first time it actually appears, which
        // may be several passes after opening: the tree fills in as directories
        // are read, so the row a reader left selected does not exist yet on the
        // pass that draws the root.
        // Claimed the first time the row actually appears, which may be several
        // passes after opening: the tree fills in as directories are read, so
        // the row a reader left at the top does not exist yet on the pass that
        // draws the root.
        if let wanted = pendingTreeScroll,
            treeRows.contains(where: { $0.path == wanted })
        {
            pendingTreeScroll = nil
            scrollTarget = ScrollTarget(mode: .browse, id: wanted)
        }

        if let wanted = pendingSelection,
            let index = treeRows.firstIndex(where: { $0.path == wanted })
        {
            pendingSelection = nil
            treeSelectedIndex = index
            return
        }
        treeSelectedIndex = min(max(0, treeSelectedIndex), treeRows.count - 1)
    }

    public func moveTreeSelection(by delta: Int) {
        guard !treeRows.isEmpty else { return }
        treeSelectedIndex = min(
            max(0, treeSelectedIndex + delta), treeRows.count - 1
        )
    }

    /// Told by the view which row is at the top, as the reader scrolls.
    public func noteScrollTop(_ id: String?, in mode: FilePickerMode) {
        switch mode {
        case .browse: treeScrollTop = id
        case .search: searchScrollTop = id
        }
    }

    /// Taken by the view once it has scrolled there.
    public func clearScrollTarget() {
        scrollTarget = nil
    }

    public func selectTreeRow(_ row: FileTreeOutline.Row) {
        guard let index = treeRows.firstIndex(where: { $0.id == row.id }) else {
            return
        }
        treeSelectedIndex = index
    }

    private var selectedTreeRow: FileTreeOutline.Row? {
        treeRows.indices.contains(treeSelectedIndex)
            ? treeRows[treeSelectedIndex] : nil
    }

    /// The right arrow: open a folder. Nothing on a file.
    public func expandSelectedTreeRow() {
        guard let row = selectedTreeRow, row.isDirectory, !row.isExpanded else {
            return
        }
        outline.expand(row.path)
        refreshTree()
    }

    /// The left arrow: close a folder, or step out to the parent when there is
    /// nothing to close.
    ///
    /// A folder the *filter* opened is not closed, because closing it would hide
    /// the match that put it on screen — so it steps to the parent instead,
    /// which is what `isRevealedByFilter` is read for.
    public func collapseSelectedTreeRow() {
        guard let row = selectedTreeRow else { return }
        if row.isDirectory, row.isExpanded, !row.isRevealedByFilter {
            outline.collapse(row.path)
            refreshTree()
            return
        }
        selectParentOfSelectedTreeRow()
    }

    private func selectParentOfSelectedTreeRow() {
        guard let row = selectedTreeRow, row.depth > 0 else { return }
        // The nearest row above it that is shallower is its parent, because the
        // list is depth-first — no parent pointer needed, and none stored.
        for index in stride(from: treeSelectedIndex - 1, through: 0, by: -1)
        where treeRows[index].depth < row.depth {
            treeSelectedIndex = index
            return
        }
    }

    /// Return: open a file, or toggle a folder.
    public func activateSelectedTreeRow() {
        guard let row = selectedTreeRow else { return }
        guard row.isDirectory else {
            dismiss()
            onOpen(URL(fileURLWithPath: row.path))
            return
        }
        if row.isExpanded, row.isRevealedByFilter { return }
        outline.toggle(row.path)
        refreshTree()
    }

    /// ⌘Return: browse this folder as the root, which is the same act as typing
    /// its path into the field.
    public func rerootToSelectedTreeRow() {
        guard let row = selectedTreeRow, row.isDirectory else { return }
        changeRoot(to: URL(fileURLWithPath: row.path))
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
        // The tree was a view of the old root, so it is rebuilt rather than
        // re-rooted: every expansion in it names a path that is no longer where
        // the reader is.
        resetBrowseState()
        buildIndex()
        if mode == .browse { refreshTree() }
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
        let store = FileCorpusStore.shared
        let held = store.hasCorpus(forCanonicalRoot: canonical) ? true : false

        // The rows are deliberately left alone when there is nothing held. What
        // is showing at this moment is the closed-and-recent list `present()`
        // offered before the walk started — the host's own history, which owes
        // the corpus nothing — and clearing it made a reader watch a tree be
        // indexed before they could reopen the file they just closed.
        indexedCount = store.indexedCount(forCanonicalRoot: canonical)
        corpusWasTruncated = false

        // Said while there is nothing at all to rank against. Opening never
        // re-walks a root it already holds, so this never says "indexing…"
        // twice for the same tree. The sweep does rewalk, shard by shard, and
        // deliberately does not touch this: a background refresh of a corpus
        // that already answers queries is not something to interrupt a reader
        // with.
        isIndexing = !held

        store.index(
            root: root,
            onProgress: { [weak self] count in
                // A count, and only a count.
                //
                // The index this replaced handed back *batches of files*, and
                // every batch drove a full re-rank: sixty-three overlapping
                // ranking passes for one walk, none of them stoppable, fifteen
                // cores busy. Progress moves a number. Rows move when the walk
                // finishes, or when the reader types.
                guard let self, let current = self.root,
                    FilePaths.canonical(current) == canonical
                else { return }
                self.indexedCount = count
            },
            onFinished: { [weak self] in
                guard let self, let current = self.root,
                    FilePaths.canonical(current) == canonical
                else { return }
                self.indexedCount = FileCorpusStore.shared
                    .indexedCount(forCanonicalRoot: canonical)
                self.isIndexing = false
                self.refreshApplicableRows()
            }
        )

        refreshApplicableRows()
    }

    /// Rebuild whichever of the two answers is on screen.
    ///
    /// Every caller that used to say `refreshRows` unconditionally was making
    /// the same mistake twice over: it left the other tab holding a stale
    /// answer, and because refreshing cancels the running scan, it *killed* the
    /// other tab's in-flight one. A filter typed in Browse while the walk was
    /// still going never came back, because the walk finishing refreshed a list
    /// nobody was looking at.
    private func refreshApplicableRows() {
        if mode == .browse { refreshTree() } else { refreshRows() }
    }

    private func refreshRows() {
        filterTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rows = FilePickerRanking.emptyQueryList(
                closed: closedProvider(),
                recent: recentProvider(),
                root: root ?? URL(fileURLWithPath: NSHomeDirectory())
            )
            resetSelection()
            return
        }

        guard let root,
            case let slices = FileCorpusStore.shared.slices(
                forCanonicalRoot: FilePaths.canonical(root)
            ),
            !slices.isEmpty
        else {
            // Cleared rather than left. This is reached only with a real query
            // typed, so whatever is showing answers the *previous* one — and
            // presenting it under the new query says those are its results.
            // Nothing, with "Reading the folder…" underneath, is true.
            rows = []
            resetSelection()
            return
        }

        // The flag is *swapped*, not merely set: the outgoing scan is poisoned
        // and the incoming one gets a fresh flag, so a pass that finishes late
        // cannot land its rows on a query typed past it.
        let browseRoot = FilePaths.canonical(root)
        filterCancellation.cancel()
        let cancellation = FileMatcher.Cancellation()
        filterCancellation = cancellation

        // Off the main actor, and genuinely cancellable — cancelling the task
        // alone stopped the await and left the scan running, which is how one
        // walk became sixty-three concurrent ranking passes.
        filterTask = Task {
            let matched = await Task.detached(priority: .userInitiated) {
                FilePickerRanking.matches(
                    slices, query: trimmed, relativeTo: browseRoot,
                    cancellation: cancellation
                )
            }.value
            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            rows = matched
            resetSelection()
        }
    }

}
