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
    init() {
        rootFieldModel.route = { [weak self] in self?.root }
        rootFieldModel.onCommit = { [weak self] url in self?.applyRoot(url) }
    }

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

    private(set) var root: URL?
    let focus = ModalFocusCapture()
    private let engine = FileSearchEngine()

    /// The root field, shared with the picker so the two panels cannot come to
    /// disagree about what Tab does in one.
    ///
    /// Observed by the field's own view rather than forwarded through here: the
    /// view is the only thing that reads it, so a second hop would invalidate
    /// the whole card to redraw one row.
    public let rootFieldModel = FileRootFieldModel()

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
        rootFieldModel.reset()
        restoreState()
        focus.arm(
            isActive: { [weak self] in self?.isPresented ?? false },
            onEscape: { [weak self] in
                guard let self else { return }
                // Innermost surface first. The root field is a surface inside
                // the panel, so it answers Escape before the panel does — the
                // same ladder Escape follows everywhere else in these apps.
                if self.rootFieldModel.isEditing {
                    self.rootFieldModel.revert()
                } else {
                    self.dismiss()
                }
            }
        )
        // The picker's card, if that is what this is replacing, still holds the
        // caret — so the note just captured names a field about to go.
        focus.adopt(from: FilePickerPresenter.shared.focus)
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

    /// A folder the root field settled on.
    private func applyRoot(_ url: URL) {
        root = url
        onChangeRoot(url)
        // **The query survives, and that is the opposite of what the picker
        // does.** There the query *was* the path and has been spent; here you
        // changed folders in order to ask the same question somewhere else, so
        // clearing it would throw away the thing you came for.
        //
        // The last run does not survive: it describes a root that is no longer
        // the one being asked about.
        lastRun = nil
        // Asked for, because `slices` answers nothing for a root nobody has
        // mapped — even one wholly inside an indexed tree.
        mapIndex()
    }

    private func mapIndex() {
        guard let root else { return }
        Task { await FileCorpusStore.shared.index(root: root) }
    }

    // MARK: - Searching

    public func toggleCaseSensitivity() {
        isCaseSensitive.toggle()
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
