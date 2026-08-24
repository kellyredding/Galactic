import Combine
import Foundation

/// The cross-file search panel.
///
/// Mounted the way the picker is, by the host:
///
/// ```swift
/// @ObservedObject private var searcher = FileSearchPresenter.shared
///
/// reader.overlay(alignment: .top) {
///     if searcher.isPresented { FileSearchView().transition(.opacity) }
/// }
/// .animation(.easeInOut(duration: 0.12), value: searcher.isPresented)
/// ```
///
/// Per file set, keyed by an opaque owner id the host supplies: each set
/// remembers its own query and its own case setting, and switching sets
/// switches which search you are looking at.
@MainActor
public final class FileSearchPresenter: ObservableObject {

    public static let shared = FileSearchPresenter()

    /// Internal so the package's tests can drive an instance without mutating
    /// the singleton every other test shares. Hosts use `shared`.
    init() {}

    // MARK: - What the host answers

    /// Where to search. The set's root, which is also the picker's.
    public var rootProvider: () -> URL? = { nil }

    /// Which file set this is. `FileSet.ownerID` — a session id in one host, a
    /// constant in the other.
    public var ownerProvider: () -> String = { "" }

    /// How many lines either side of a match to show.
    ///
    /// Asked rather than stored, because it is the host's setting: it decides
    /// how much of a file a reader is shown, which two applications may
    /// legitimately answer differently. Contrast the index's skip list, which
    /// had to stop being per-application because two hosts describing one
    /// corpus differently is a contradiction rather than a preference.
    public var contextLinesProvider: () -> Int = { 2 }

    /// A finished run, for the host to write and open.
    public var onRun: (FileSearchRun) -> Void = { _ in }

    /// A root the reader chose. The panel does not own the root; it reports a
    /// change and the host applies it, same as the picker.
    public var onChangeRoot: (URL) -> Void = { _ in }

    // MARK: - State

    @Published public var query = ""
    @Published public private(set) var isCaseSensitive = false
    @Published public private(set) var isPresented = false
    @Published public private(set) var isSearching = false

    /// The last run this owner saw, for the panel to summarise. Not the results
    /// themselves — those are a tab.
    @Published public private(set) var lastRun: FileSearchRun?

    // MARK: - The root field

    @Published public private(set) var rootField = FileRootField()
    @Published public private(set) var rootRows: [FilePickerItem] = []

    /// Whether the caret is in the root field rather than the query.
    ///
    /// Held here rather than read off the view because Escape is answered by a
    /// key monitor the presenter installs, and that monitor has to know which
    /// surface is innermost before deciding what closing means.
    @Published public private(set) var isEditingRoot = false

    /// One directory per parent, dropped whenever the panel opens.
    ///
    /// Dropped on open rather than on a timer: a folder made since the last
    /// look should appear, and opening is when a reader asks.
    private var folderCache: (parent: String, children: [String])?
    private var loadingParent: String?

    private(set) var root: URL?
    let focus = ModalFocusCapture()
    private let engine = FileSearchEngine()

    /// Which owner this panel was opened for.
    ///
    /// Captured at `present()` rather than asked again at `dismiss()`, because
    /// a host is free to switch file sets while the panel is up: asking a second
    /// time files one set's query under another set's key, and the wrong query
    /// then comes back for both. The same shape as recording the key window
    /// alongside the responder rather than re-resolving it.
    private var presentedOwner: String?

    /// Read as a stand-down gate by every monitor answering a bare key, through
    /// `GalacticModals`.
    public static var isClaimingKeyboard: Bool { shared.isPresented }

    // MARK: - Per-owner memory

    /// In memory only, and deliberately: a query is cheap to retype, and the
    /// root it was asked against may have moved by the next launch. The same
    /// argument the picker's saved state records.
    private var saved: [String: SessionState] = [:]

    private struct SessionState {
        var query: String
        var isCaseSensitive: Bool
        var lastRun: FileSearchRun?
        /// Canonical. A host that re-rooted since discards the whole entry —
        /// a query is about a root, and answering it against a different one
        /// would be a different question.
        var root: String
    }

    // MARK: - Opening and closing

    public func toggle() {
        isPresented ? dismiss() : present()
    }

    public func present() {
        guard !isPresented else { return }

        // One card, one anchor. Both panels hang top-centre under the tab strip
        // at the same width, so two open at once would overlap — and both would
        // hold live Escape monitors with no contracted ordering between them.
        FilePickerPresenter.shared.dismiss()

        root = rootProvider()
        presentedOwner = ownerProvider()
        folderCache = nil
        isEditingRoot = false
        rootRows = []
        rootField.reset(to: root)
        restoreState()
        focus.arm(
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in
                guard let self else { return }
                // Innermost surface first. The root field is a surface inside
                // the panel, so it answers Escape before the panel does — the
                // same ladder Escape follows everywhere else in these apps.
                if self.isEditingRoot {
                    self.revertRootField()
                } else {
                    self.dismiss()
                }
            }
        )
        isPresented = true

        // The corpus has to have been asked for before it answers: `slices`
        // alone returns nothing for a root nobody has mapped, even one wholly
        // inside an indexed tree. Measured — a project subtree of an indexed
        // home returned zero files until its own `index` call resolved the
        // covering shards, which read as "no matches" rather than as "not
        // indexed yet".
        mapIndex()
    }

    public func dismiss() {
        rememberState()
        isPresented = false
        engine.cancel()
        isSearching = false
        focus.disarm()
    }

    /// Called by the view as it disappears, never by `dismiss` — see
    /// `ModalFocusCapture.restore` for why that ordering is the whole argument.
    func restoreFocus() {
        focus.restore()
    }

    private func rememberState() {
        guard let root, let owner = presentedOwner else { return }
        saved[owner] = SessionState(
            query: query,
            isCaseSensitive: isCaseSensitive,
            lastRun: lastRun,
            root: FilePaths.canonical(root)
        )
    }

    private func restoreState() {
        let canonical = root.map { FilePaths.canonical($0) }
        guard let owner = presentedOwner, let state = saved[owner],
            state.root == canonical
        else {
            query = ""
            isCaseSensitive = false
            lastRun = nil
            return
        }
        query = state.query
        isCaseSensitive = state.isCaseSensitive
        lastRun = state.lastRun
    }

    private func mapIndex() {
        guard let root else { return }
        FileCorpusStore.shared.index(root: root)
    }

    // MARK: - Searching

    public func toggleCaseSensitivity() {
        isCaseSensitive.toggle()
    }

    // MARK: - Re-rooting

    /// Shift-Tab. Fill the field from the root and take the caret.
    ///
    /// Filled every time rather than kept, so the field always opens saying
    /// where you actually are — a half-typed path abandoned last time is not an
    /// answer to that question.
    public func beginEditingRoot() {
        rootField.reset(to: root)
        isEditingRoot = true
        refreshRootRows()
    }

    /// Focus went back to the query. Nothing is committed by leaving.
    public func endEditingRoot() {
        isEditingRoot = false
        rootRows = []
    }

    public func editRootText(_ text: String) {
        guard text != rootField.text else { return }
        rootField.text = text
        // Typing invalidates a pick: the row that was chosen may not even be
        // offered any more, and carrying the index over would commit whichever
        // folder happened to land at it.
        rootField.clearSelection()
        refreshRootRows()
    }

    /// Tab.
    public func completeRootPath() {
        guard let parent = rootField.candidateParent(route: routePath) else {
            return
        }
        let children = cachedChildren(of: parent) ?? readChildren(of: parent)
        guard
            let completed = rootField.completion(
                directories: children, route: routePath
            )
        else { return }
        rootField.text = completed
        rootField.clearSelection()
        refreshRootRows()
    }

    public func moveRootSelection(by delta: Int) {
        rootField.moveSelection(by: delta, rowCount: rootRows.count)
    }

    public func pickRootRow(_ index: Int) {
        guard rootRows.indices.contains(index) else { return }
        rootField.moveSelection(
            by: index - (rootField.selection ?? -1), rowCount: rootRows.count
        )
    }

    /// Return. Commit, or refuse and stay.
    ///
    /// Refusing rather than closing is the point: a path that names nothing is a
    /// typo, and dropping the caret back into the query field would hide it.
    public func commitRootField() {
        guard let url = rootField.resolved(rows: rootRows, route: routePath)
        else { return }
        changeRoot(to: url)
        endEditingRoot()
    }

    /// Escape. Put back what was there and leave.
    public func revertRootField() {
        rootField.reset(to: root)
        endEditingRoot()
    }

    private func changeRoot(to url: URL) {
        root = url
        onChangeRoot(url)
        rootField.reset(to: url)
        // **The query survives, and that is the opposite of what the picker
        // does.** There the query *was* the path and has been consumed; here you
        // re-rooted in order to run the same query somewhere else, so clearing
        // it would throw away the thing you came for.
        //
        // The last run does not survive: it describes a root that is no longer
        // the one being asked about.
        lastRun = nil
        folderCache = nil
        // Asked for, because `slices` answers nothing for a root nobody has
        // mapped — even one wholly inside an indexed tree.
        mapIndex()
    }

    private var routePath: String? { root?.path }

    private func cachedChildren(of parent: String) -> [String]? {
        folderCache?.parent == parent ? folderCache?.children : nil
    }

    private func readChildren(of parent: String) -> [String] {
        let children = FileDirectoryReader.childDirectories(of: parent)
        folderCache = (parent, children)
        return children
    }

    /// Offer the folders for what is typed.
    ///
    /// Cached parents answer on the spot; a new one is read off the main actor
    /// and lands when it lands. The same shape the tree's expansion uses, and
    /// for the measured reason recorded there: a `readdir` on the draw path cost
    /// 194 ms for a 2,392-entry directory.
    private func refreshRootRows() {
        guard isEditingRoot, let parent = rootField.candidateParent(route: routePath)
        else {
            rootRows = []
            return
        }

        if let children = cachedChildren(of: parent) {
            rootRows = rootField.rows(children: children, route: routePath)
            return
        }

        // Cleared before the read, not after it. What is showing belongs to the
        // previous parent, and showing another directory's folders under a path
        // being typed is worse than showing none — it flashes a wrong answer
        // long enough to act on.
        rootRows = []
        rootField.clearSelection()

        guard loadingParent != parent else { return }
        loadingParent = parent
        let route = routePath
        Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) {
                FileDirectoryReader.childDirectories(of: parent)
            }.value
            guard let self, self.isEditingRoot else { return }
            self.loadingParent = nil
            self.folderCache = (parent, children)
            // Re-asked rather than captured: the field has probably moved on.
            guard self.rootField.candidateParent(route: route) == parent else {
                return
            }
            self.rootRows = self.rootField.rows(
                children: children, route: route
            )
        }
    }

    /// Run the search. Return, and nothing else.
    ///
    /// Nothing runs while typing: reading every byte of every file under a root
    /// is orders of magnitude dearer than the picker's in-memory path match, so
    /// a debounced live search would cancel and restart full scans for as long
    /// as a reader kept typing.
    public func commit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let root else { return }

        isSearching = true
        engine.search(
            query: FileSearchQuery(
                text: text,
                isCaseSensitive: isCaseSensitive,
                contextLines: contextLinesProvider()
            ),
            root: root
        ) { [weak self] run in
            guard let self else { return }
            self.isSearching = false
            self.lastRun = run
            // Dismissed before handing over, like the picker's open, so a host
            // acting synchronously need not think about ordering.
            self.dismiss()
            self.onRun(run)
        }
    }
}
