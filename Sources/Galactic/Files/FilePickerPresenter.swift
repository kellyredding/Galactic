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

    /// **A finished index is never re-walked**, and it is held by
    /// `FileCorpusStore` rather than here.

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
        let store = FileCorpusStore.shared
        let held = store.hasCorpus(forCanonicalRoot: canonical) ? true : false

        // The rows are deliberately left alone when there is nothing held. What
        // is showing at this moment is the closed-and-recent list `present()`
        // offered before the walk started — the host's own history, which owes
        // the corpus nothing — and clearing it made a reader watch a tree be
        // indexed before they could reopen the file they just closed.
        indexedCount = store.indexedCount(forCanonicalRoot: canonical)
        corpusWasTruncated = false

        // Said while there is nothing at all to rank against. A root already
        // walked is never re-walked, so it never says "indexing…" twice.
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
            case let slices = FileCorpusStore.shared.slices(
                forCanonicalRoot: FilePaths.canonical(root)
            ),
            !slices.isEmpty
        else { return }

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
            selectedIndex = 0
        }
    }
}
