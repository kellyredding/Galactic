import AppKit
import Combine
import Foundation

/// Presentation state for the file picker: whether it is up, what it is
/// offering, and what is selected.
///
/// An in-window overlay on the `CheatSheetPresenter` pattern, mounted by the
/// host:
///
/// ```swift
/// @ObservedObject private var picker = FilePickerPresenter.shared
///
/// .overlay {
///     if picker.isPresented { FilePickerView().transition(.opacity) }
/// }
/// .animation(.easeInOut(duration: 0.12), value: picker.isPresented)
/// ```
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

    /// The corpus, walked once per open.
    private var index: FileTreeIndex?

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

    private func buildIndex() {
        guard let root else {
            index = nil
            rows = []
            return
        }
        isIndexing = true
        let target = root
        // Resolved here rather than inside the detached task, so the provider is
        // called on the main actor with the rest of the host's state.
        let skipping = skipListProvider()
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                FileTreeIndex.build(root: target, skipping: skipping)
            }.value
            guard !Task.isCancelled else { return }
            index = built
            corpusWasTruncated = built.wasTruncated
            isIndexing = false
            refreshRows()
        }
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
