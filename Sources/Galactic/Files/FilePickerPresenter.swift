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

    /// The corpus in front of the reader right now.
    private var index: FileTreeIndex?

    /// One walked tree, and when it was walked.
    private struct Corpus {
        let index: FileTreeIndex
        let builtAt: Date
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

    /// How many trees are kept. Small — this is a return trip, not a history.
    private static let corpusLimit = 4

    /// How stale a held index may be before an open refreshes it.
    ///
    /// A refresh is a whole enumeration of the tree, so doing one per open spends
    /// real disk on a question the reader did not ask — and on a root that
    /// crosses protected directories it is also a permission prompt per walk.
    /// Files created since are found by the next refresh rather than instantly,
    /// which is the trade a corpus this size forces.
    private static let refreshWindow: TimeInterval = 600

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
            index = nil
            rows = []
            return
        }

        let canonical = FilePaths.canonical(root)
        let held = corpora[canonical]

        // The rows are deliberately left alone when there is no held index. What
        // is showing at this moment is the closed-and-recent list `present()`
        // offered before the walk started — the host's own history, which owes
        // the corpus nothing — and clearing it made a reader watch a tree be
        // indexed before they could reopen the file they just closed.
        index = held?.index
        corpusWasTruncated = held?.index.wasTruncated ?? false
        indexedCount = held?.index.items.count ?? 0

        // Only claimed while there is genuinely nothing to rank against. A
        // refresh behind a usable index is not something to report — it would put
        // "indexing…" in the corner every time the picker opened.
        isIndexing = index == nil

        // Nothing to do: a usable index that is not stale yet.
        if let held, Date().timeIntervalSince(held.builtAt) < Self.refreshWindow
        {
            refreshRows()
            return
        }

        // Already being walked. Two opens must not become two enumerations.
        guard !walksInFlight.contains(canonical) else {
            refreshRows()
            return
        }
        walksInFlight.insert(canonical)

        let target = root
        // Resolved here rather than inside the detached task, so the provider is
        // called on the main actor with the rest of the host's state.
        let skipping = skipListProvider()
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                FileTreeIndex.build(root: target, skipping: skipping)
            }.value
            walksInFlight.remove(canonical)
            guard !Task.isCancelled else { return }

            // Kept whatever the reader is looking at now: a walk that finished
            // after they re-rooted is still the right answer for the tree it
            // walked, and throwing it away would make the trip back expensive
            // again. Keyed by the walk's own resolved root, which is canonical by
            // construction.
            remember(built)

            // Only shown if it is still the tree on screen.
            guard target.path == self.root?.path else { return }
            index = built
            corpusWasTruncated = built.wasTruncated
            indexedCount = built.items.count
            isIndexing = false
            refreshRows()
        }
    }

    /// Hold a walked tree, evicting the oldest once there are too many.
    private func remember(_ built: FileTreeIndex) {
        corpora[built.root.path] = Corpus(index: built, builtAt: Date())
        guard corpora.count > Self.corpusLimit else { return }
        let oldest = corpora.min { $0.value.builtAt < $1.value.builtAt }
        if let key = oldest?.key { corpora[key] = nil }
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

        guard let items = index?.items else { return }
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
