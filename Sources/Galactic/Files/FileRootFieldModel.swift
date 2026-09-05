import Combine
import Foundation

/// A panel's root field, working.
///
/// The state `FileRootField` decides, plus the directory reads and the caret
/// bookkeeping that cannot live in a value. Both panels hold one; neither owns
/// the behaviour, which is the point — two copies of "what Tab does here" is how
/// the two panels would come to disagree about it.
///
/// The owner supplies where it currently is and what applying a folder means,
/// and nothing else: this type never touches a corpus, a query, or a tab.
@MainActor
public final class FileRootFieldModel: ObservableObject {

    /// Where the panel says it is. What a relative path is relative to.
    public var route: () -> URL?

    /// Apply a chosen folder. Called only for a folder that exists.
    public var onCommit: (URL) -> Void

    @Published public private(set) var field = FileRootField()
    @Published public private(set) var rows: [FilePickerItem] = []

    /// Whether the caret is in this field.
    ///
    /// Published because Escape is answered by a key monitor the *presenter*
    /// installs, and that monitor has to know whether a surface inside the panel
    /// is claiming the key before deciding what closing means.
    @Published public private(set) var isEditing = false

    /// One directory per parent. Dropped when the panel opens rather than on a
    /// timer: a folder made since the last look should appear, and opening is
    /// when a reader asks.
    ///
    /// Internal rather than private so a test can assert which parent is held —
    /// a read landing for a parent the field has left used to evict the one it
    /// had not, and from outside that is visible only as a keystroke that went
    /// to the disk instead of answering from memory.
    var cache: (parent: String, children: [String])?
    private var loadingParent: String?

    public init(
        route: @escaping () -> URL? = { nil },
        onCommit: @escaping (URL) -> Void = { _ in }
    ) {
        self.route = route
        self.onCommit = onCommit
    }

    // MARK: - Opening and leaving

    /// The panel opened. Forget everything read for the last one.
    public func reset() {
        cache = nil
        loadingParent = nil
        isEditing = false
        rows = []
        field.reset(to: route())
    }

    /// The caret arrived. Fill from the root and offer what is inside.
    ///
    /// Refilled every time rather than kept, so the field always says where you
    /// actually are — a path abandoned last time is not an answer to that.
    public func beginEditing() {
        field.reset(to: route())
        isEditing = true
        refreshRows()
    }

    /// The caret left. Nothing is applied by leaving.
    public func endEditing() {
        isEditing = false
        rows = []
    }

    /// The root moved, and not by anything this field did.
    ///
    /// The field shows a value rather than deriving one, so a root changed from
    /// somewhere else — a folder picked in the tree, a reveal aiming the panel
    /// at another file — leaves it naming where the reader used to be until the
    /// caret lands in it and `beginEditing` refills it.
    ///
    /// **Refuses while the caret is in the field.** Rewriting a path someone is
    /// halfway through typing is worse than showing a stale one, and the commit
    /// path needs no help: it re-reads for itself once its own change has been
    /// applied.
    public func noteRootChanged() {
        guard !isEditing else { return }
        field.reset(to: route())
    }

    // MARK: - Typing

    public func edit(_ text: String) {
        guard text != field.text else { return }
        field.text = text
        // Typing invalidates a pick: the row that was chosen may not even be
        // offered now, and carrying the index over would apply whichever folder
        // happened to land at it.
        field.clearSelection()
        refreshRows()
    }

    /// Tab.
    ///
    /// Reads the directory **synchronously** when the cache misses, unlike the
    /// row refresh below. A keypress has to answer now; a list is incidental and
    /// is allowed to arrive. It is also the same cache the list fills, so Tab
    /// and the list can never disagree about what is in a directory.
    public func complete() {
        guard let parent = field.candidateParent(route: routePath) else {
            return
        }
        let children = cachedChildren(of: parent) ?? readChildren(of: parent)
        guard
            let completed = field.completion(
                directories: children, route: routePath
            )
        else { return }
        field.text = completed
        field.clearSelection()
        refreshRows()
    }

    public func moveSelection(by delta: Int) {
        field.moveSelection(by: delta, rowCount: rows.count)
    }

    public func pick(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        field.moveSelection(
            by: index - (field.selection ?? -1), rowCount: rows.count
        )
    }

    // MARK: - Leaving with, or without, a change

    /// Return. Apply, or refuse and stay.
    ///
    /// Refusing rather than closing is the point: a path that names nothing is a
    /// typo, and dropping the caret elsewhere would hide it.
    ///
    /// - Returns: whether anything was applied, so an owner can decide what else
    ///   a change means to it.
    @discardableResult
    public func commit() -> Bool {
        guard let url = field.resolved(rows: rows, route: routePath) else {
            return false
        }
        onCommit(url)
        // Re-read rather than assumed: the owner may have canonicalised or
        // refused the folder, and the field should say what actually happened.
        field.reset(to: route())
        cache = nil
        endEditing()
        return true
    }

    /// Escape. Put back what was there and leave.
    public func revert() {
        field.reset(to: route())
        endEditing()
    }

    // MARK: - Offering folders

    private var routePath: String? { route()?.path }

    private func cachedChildren(of parent: String) -> [String]? {
        cache?.parent == parent ? cache?.children : nil
    }

    @discardableResult
    private func readChildren(of parent: String) -> [String] {
        let children = FileDirectoryReader.childDirectories(of: parent)
        cache = (parent, children)
        return children
    }

    /// A cached parent answers on the spot; a new one is read off the main actor
    /// and lands when it lands — the shape the tree's expansion uses, for the
    /// measured reason recorded there: a directory read on the draw path cost
    /// 194 ms for a 2,392-entry folder.
    private func refreshRows() {
        guard isEditing, let parent = field.candidateParent(route: routePath)
        else {
            rows = []
            return
        }

        if let children = cachedChildren(of: parent) {
            rows = field.rows(children: children, route: routePath)
            return
        }

        // Cleared before the read, not after it. What is showing belongs to the
        // previous parent, and another directory's folders under a path being
        // typed is worse than none — it flashes a wrong answer long enough to
        // act on.
        rows = []
        field.clearSelection()

        guard loadingParent != parent else { return }
        loadingParent = parent
        let route = routePath
        Task { [weak self] in
            let children = await Task.detached(priority: .userInitiated) {
                FileDirectoryReader.childDirectories(of: parent)
            }.value
            guard let self, self.isEditing else { return }
            // Only this read's own claim is released. Clearing it outright let
            // a read that finished late release the claim a *different* parent
            // had taken since, so the next keystroke started a second read of
            // a directory already being read.
            if self.loadingParent == parent { self.loadingParent = nil }
            // Re-asked rather than captured: more may have been typed while the
            // directory was read, and the rows must answer the field as it
            // stands.
            guard self.field.candidateParent(route: route) == parent else {
                return
            }
            // **Held only while still wanted, and that is below the guard for a
            // reason.** One slot holds one parent, so a read landing for a
            // parent the field has left does not merely waste its result — it
            // evicts the parent the reader is actually typing in. Two reads are
            // in flight together routinely, because the field opens on a path
            // with no trailing slash and so reads the route's *parent* first,
            // then reads the route itself as soon as a separator is typed. When
            // that first directory is the larger of the two it lands second,
            // and every keystroke after it paid for a fresh read of a directory
            // whose children were already in hand — the 194 ms per draw this
            // cache exists to avoid.
            self.cache = (parent, children)
            self.rows = self.field.rows(children: children, route: route)
        }
    }
}
