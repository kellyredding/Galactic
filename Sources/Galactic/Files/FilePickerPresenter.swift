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

    /// Whether the reader moved to the selection, rather than it being the
    /// highlighted first row of a list they have not touched.
    ///
    /// Return needs the difference: a folder chosen with the arrows outranks a
    /// path typed into the field, and a path typed in full outranks a selection
    /// nobody asked for. Cleared on every rebuild, because a list that changed
    /// underneath is not a list anyone has chosen from.
    private var selectionIsExplicit = false

    /// The root being browsed, shown above the field so a reader can see which
    /// tree they are searching before they wonder why a file is missing.
    @Published public private(set) var root: URL?

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
        resetSelection()
        // Dropped on open rather than on a timer: a folder created since the
        // last look should appear, and opening is the moment a reader asks.
        folderCache = nil
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
        selectionIsExplicit = true
    }

    /// Back to the first row, and to nobody having chosen it.
    private func resetSelection() {
        selectedIndex = 0
        selectionIsExplicit = false
    }

    /// Act on the selection, or re-root to what has been typed.
    ///
    /// Four rules in this order, and the order is the whole of the design.
    /// Before folders were listed a path query had no rows at all, so "re-root
    /// to the text" could come first and always win. Now it usually has rows,
    /// and Return has to tell apart *the folder I picked* from *the folder I
    /// named*:
    ///
    /// 1. A selection the reader moved to wins over everything. They chose it.
    /// 2. Otherwise a path ending in a separator re-roots to that path — a
    ///    reader who typed `~/projects/` in full named that folder, and diving
    ///    into whichever child happened to sort first would be startling.
    /// 3. Otherwise the selection, which is the highlighted first match: typing
    ///    `~/pro` and pressing Return goes into `projects`.
    /// 4. Otherwise the typed path, which is the case where it was typed past
    ///    every match — nothing is listed and the text is all there is.
    public func commit() {
        if selectionIsExplicit, rows.indices.contains(selectedIndex) {
            activate(rows[selectedIndex])
            return
        }
        if let path = FilePickerRootInput.expandedPath(query, route: route),
            path.hasSuffix("/")
        {
            changeRoot(to: URL(fileURLWithPath: path))
            return
        }
        if rows.indices.contains(selectedIndex) {
            activate(rows[selectedIndex])
            return
        }
        if let path = FilePickerRootInput.expandedPath(query, route: route) {
            changeRoot(to: URL(fileURLWithPath: path))
        }
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

    /// Put the reader on the path-typing route, from the header's folder chip.
    ///
    /// Prefills the field with the root's own path rather than opening a folder
    /// dialog, and that is the point: typing a path *is* how the root changes
    /// here, and the affordance that changes it should teach the mechanism
    /// instead of routing around it. The trailing separator lands the reader on
    /// a listing of the root's own children, so the mechanism demonstrates
    /// itself rather than being described.
    public func beginRootChange() {
        let home = NSHomeDirectory()
        let path = root?.path ?? home
        query =
            (path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count) : path) + "/"
    }

    /// Extend a partly-typed path, the way a shell's Tab does.
    public func completePath() {
        guard
            let parent = FilePickerRootInput.candidateParent(
                of: query, route: route
            )
        else { return }
        // The same children the folder list is showing, from the same cache, so
        // Tab and the list can never disagree about what is in a directory.
        // They each read the disk separately before this.
        let candidates =
            folderCache?.parent == parent
            ? folderCache?.children ?? []
            : Self.childDirectories(of: parent)
        guard
            let completed = FilePickerRootInput.completion(
                for: query, directories: candidates, route: route
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
                self.refreshRows()
            }
        )

        refreshRows()
    }

    private func refreshRows() {
        filterTask?.cancel()

        // A path being typed is still not a filter — the corpus is still not
        // consulted — but the reader now sees the folders they are choosing
        // between rather than a hint describing them.
        if FilePickerRootInput.isRootChange(query, route: route) {
            refreshFolderRows()
            return
        }

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

    // MARK: - The folders a typed path is choosing between

    /// The last directory read, held so that typing inside one costs one
    /// directory read rather than one per keystroke.
    ///
    /// This bound is not an optimisation. A `readdir` plus a `resourceValues`
    /// per entry, on the main actor, once per keystroke, in the most-typed
    /// field in the picker, is the shape of the beach ball this index was
    /// already fixed for once — where `stat` accounted for 213 ms of a 218 ms
    /// burst. The parent only changes when a separator is typed or completed,
    /// so a burst of keystrokes inside one directory reads nothing.
    private var folderCache: (parent: String, children: [String])?

    private func refreshFolderRows() {
        guard
            let parent = FilePickerRootInput.candidateParent(
                of: query, route: route
            )
        else {
            rows = []
            resetSelection()
            return
        }

        if let cached = folderCache, cached.parent == parent {
            rows = FilePickerFolderList.rows(
                for: query, children: cached.children, route: route
            )
            resetSelection()
            return
        }

        // Cleared before the read, not after it. Whatever is showing belongs to
        // the previous query, and under a half-typed path that is a list of
        // *files* — the very thing this mode exists not to show. A read takes
        // long enough to see, so leaving them would flash the wrong answer.
        rows = []
        resetSelection()

        filterTask = Task {
            let children = await Task.detached(priority: .userInitiated) {
                Self.childDirectories(of: parent)
            }.value
            guard !Task.isCancelled else { return }
            folderCache = (parent, children)

            // The query is read *after* the await rather than captured before
            // it, because more may have been typed while the directory was
            // read — and the rows must answer the field as it stands, not as it
            // was. Still the same parent, or a later refresh already owns this.
            guard FilePickerRootInput.isRootChange(query, route: route),
                FilePickerRootInput.candidateParent(of: query, route: route)
                    == parent
            else { return }
            rows = FilePickerFolderList.rows(
                for: query, children: children, route: route
            )
            resetSelection()
        }
    }

    /// The child directories of a path.
    ///
    /// `nonisolated static` so the detached read above cannot reach presenter
    /// state, which is what keeps this off the main actor by construction
    /// rather than by remembering to.
    ///
    /// Hidden entries are included — `options: []` does not pass
    /// `.skipsHiddenFiles` — and that is wanted: `~/.claude` is somewhere a
    /// reader goes.
    ///
    /// **Each child is spelled against the parent it was asked for, not taken
    /// from the enumerated URL.** Measured: asked for
    /// `/var/folders/…/T/x`, `contentsOfDirectory` answers
    /// `/private/var/folders/…/T/x/alpha`, because `/var` is a symlink. Every
    /// caller here matches these against what the reader typed, so a resolved
    /// spelling fails `hasPrefix` against an unresolved one and the folder list
    /// silently comes back empty. `/tmp`, `/var` and `/etc` are all symlinks on
    /// macOS, which is why `/tmp/` has never tab-completed.
    ///
    /// Resolving the reader's text instead would be the other repair and is
    /// worse: it rewrites the field under them, and `~` is deliberately kept
    /// unexpanded there for exactly that reason.
    private nonisolated static func childDirectories(
        of path: String
    ) -> [String] {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ],
                options: []
            )
        else { return [] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return contents
            .filter(isBrowsableDirectory)
            .map { prefix + $0.lastPathComponent }
    }

    /// Whether a directory entry is somewhere the picker can browse into.
    ///
    /// **`isDirectoryKey` has `lstat` semantics: it is false for every symlink,
    /// including one pointing straight at a directory.** Measured — `/tmp`,
    /// `/var`, `/etc` and `~/projects/implementation-plans` all answer false,
    /// so enumerating `/` with that predicate alone yields no `tmp`, `var` or
    /// `etc` at all, and a symlinked project folder is invisible.
    ///
    /// `resolvingSymlinksInPath()` is not the repair: measured, it answers
    /// false for `/tmp` and true for `implementation-plans`, so it disagrees
    /// with itself. `fileExists(atPath:isDirectory:)` follows the link and was
    /// true for every case above, so the link is settled with a `stat` — but
    /// only when the entry *is* a link, which keeps one syscall off the
    /// overwhelming majority of entries that are ordinary directories.
    private nonisolated static func isBrowsableDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        if values?.isDirectory == true { return true }
        guard values?.isSymbolicLink == true else { return false }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}
