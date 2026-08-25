import AppKit
import Foundation
import WebKit

/// What an application answers about its Files surface.
///
/// Deliberately small, and the smallness is the point. Everything a host is
/// *not* asked here — what a tab is, how the strip wraps, what happens to a file
/// that will not open, when ⌘W beeps, what the escape ladder does, how a note is
/// echoed — is the same in every host, and lives in `FilesSurface`.
///
/// The one structural difference between the two applications shipping this is
/// how many owners exist. A single-session app answers `currentOwnerID` with a
/// constant forever; a multi-session one answers with whichever session is in
/// front. Both go through `FileSets`, so that difference stays a string.
@MainActor
public protocol FilesHost: AnyObject {
    /// The set the surface is acting on right now.
    var currentOwnerID: String { get }

    /// Where browsing starts for an owner, asked once when its set is created.
    func defaultRoot(forOwner ownerID: String) -> URL

    /// Bring the Files surface in front of the reader.
    func showFilesSurface()

    /// Show wherever the agent's reply will appear, after a review is sent.
    func showAgentSurface()

    /// Hand a composed review to the agent that owns this set.
    func deliverReview(_ review: String, forOwner ownerID: String)

    /// The composer's key bindings, in the shape the page wants them.
    var textEntryPayload: [String: [[String: Any]]]? { get }

    /// Lines shown either side of a hit in search results.
    var searchContextLines: Int { get }
}

/// The Files surface, minus the application.
///
/// Owns the sets, the strip operations and their refusal semantics, the panels,
/// the note layer and the search-results path. A host constructs one, answers
/// `FilesHost`, and mounts `FilesPaneView`.
///
/// **Why this exists at all.** All of it used to live in one application,
/// correctly, because there was one — and nothing about a single host can show
/// which of its code is about the application and which is about files. A second
/// host is the only test of that, and when one arrived most of the answers came
/// back "files". A behaviour changed here now reaches both apps, which is the
/// whole reason the engine was put in a package to begin with.
@MainActor
public final class FilesSurface {

    private unowned let host: FilesHost
    private let sets: FileSets

    /// Where sets are kept between launches, if anywhere.
    private weak var store: FileSetStore?

    /// Owners already restored, so a host whose view reappears on a window
    /// rebuild does not replace the strip a reader has been working in with
    /// what was on disk at launch.
    private var restoredOwners: Set<String> = []

    /// Told whenever the selected file changes, including to nothing.
    ///
    /// A hook rather than a protocol member because only one host has anything
    /// to do with it: Galaxy mirrors the selection onto its session so route
    /// history can record and restore it. A host with no history leaves it nil.
    public var onSelectionChanged: ((String?) -> Void)?

    /// The run behind a results tab, and the owner it belongs to.
    ///
    /// Held rather than baked into the file so a theme change re-renders in the
    /// new appearance. Deliberately **not** published: it is read during a view
    /// update, and publishing it there would mutate state SwiftUI is in the
    /// middle of reading.
    ///
    /// `internal` rather than `private` only because the note and results code
    /// lives in a sibling file, and `private` in Swift is file-scoped.
    var searchRun: FileSearchRun?
    var searchRunOwner: String?

    /// Where the next page build should land, consumed once.
    var pendingJump: (path: String, line: Int)?

    /// Reachable from the sibling file for the same reason as above.
    var currentHost: FilesHost { host }

    public init(host: FilesHost, store: FileSetStore? = nil) {
        self.host = host
        self.store = store
        self.sets = FileSets(defaultRoot: { [unowned host] ownerID in
            host.defaultRoot(forOwner: ownerID)
        })
    }

    // MARK: - Sets

    public func set(forOwner ownerID: String) -> FileSet {
        sets.set(forOwner: ownerID)
    }

    /// The set the host says is current.
    public var currentSet: FileSet { sets.set(forOwner: host.currentOwnerID) }

    /// The set an owner already has, without bringing one into being.
    ///
    /// The distinction matters at quit and at close, where the question is "is
    /// there anything to lose" — and asking the creating form would answer it by
    /// making an empty set for every owner that never opened Files.
    public func existingSet(forOwner ownerID: String) -> FileSet? {
        sets.existingSet(forOwner: ownerID)
    }

    public func discard(ownerID: String) {
        sets.discard(ownerID: ownerID)
    }

    /// What a quit prompt counts, across every owner.
    public var pendingNoteTally: (notes: Int, files: Int) {
        sets.pendingNoteTally
    }

    /// Write the set down and tell the host what is selected now.
    ///
    /// Every mutation ends here, so the two facts are made to agree in one place
    /// rather than once per action — and so the results-path filtering below
    /// cannot be forgotten at one call site out of eleven.
    func persist(_ set: FileSet) {
        store?.save(snapshot(of: set), forOwner: set.ownerID)
        onSelectionChanged?(set.selectedPath)
    }

    /// What a restore would need, with the results tab taken out.
    ///
    /// The results file is real, so it would come back like any other tab — and
    /// returning to yesterday's results is worse than returning to none. Dropped
    /// on the way to storage rather than made unreal, which would have cost a
    /// branch everywhere a tab is a file.
    func snapshot(of set: FileSet) -> PersistedFileSet {
        let resultsPath = Self.searchResultsURL(owner: set.ownerID).path
        return PersistedFileSet(
            root: set.root.path,
            openPathRows: set.openPathRows
                .map { row in row.filter { $0 != resultsPath } }
                .filter { !$0.isEmpty },
            selectedPath: set.selectedPath == resultsPath
                ? nil : set.selectedPath
        )
    }

    /// Rebuild an owner's set from the last write, once.
    ///
    /// **Deliberately does not persist afterwards.** A restore that dropped two
    /// deleted files and immediately saved the shortened list would make a
    /// launch on a slow network volume permanent — the next launch would have no
    /// record those files were ever open. The shortened list is written by the
    /// reader's next real change instead.
    public func restoreIfNeeded(ownerID: String) {
        guard !restoredOwners.contains(ownerID) else { return }
        restoredOwners.insert(ownerID)
        guard let saved = store?.load(forOwner: ownerID) else { return }
        let set = sets.set(forOwner: ownerID)
        if !saved.root.isEmpty {
            set.changeRoot(to: URL(fileURLWithPath: saved.root))
        }
        set.restore(
            openPathRows: saved.openPathRows, selectedPath: saved.selectedPath
        )
        onSelectionChanged?(set.selectedPath)
    }

    // MARK: - The panels

    /// Point the picker and the searcher at whichever set is current.
    ///
    /// **Providers, never captured values, and wired once for the process.**
    /// Both presenters are singletons holding one set of closures. A host with
    /// several owners that wired them per view would leave the last view to
    /// mount as the writer, and the picker would open against whichever owner
    /// that happened to be. Resolving `currentOwnerID` on every ask is what
    /// makes one wiring correct for both shapes of host.
    public func connectPresenters() {
        let picker = FilePickerPresenter.shared
        picker.rootProvider = { [weak self] in self?.currentSet.root }
        picker.ownerProvider = { [weak self] in self?.host.currentOwnerID ?? "" }
        picker.closedProvider = { [weak self] in
            self?.currentSet.closedTabs.presented() ?? []
        }
        picker.recentProvider = { [weak self] in
            self?.currentSet.presentedRecents() ?? []
        }
        picker.onOpen = { [weak self] url in self?.open(url: url) }
        picker.onChangeRoot = { [weak self] url in self?.changeRoot(to: url) }

        let searcher = FileSearchPresenter.shared
        searcher.rootProvider = { [weak self] in self?.currentSet.root }
        searcher.ownerProvider = { [weak self] in
            self?.host.currentOwnerID ?? ""
        }
        // The host's setting, not the index's: it decides how much of a file a
        // reader is shown rather than what the corpus holds, which is why two
        // applications may answer it differently without contradicting one
        // another about what is indexed.
        searcher.contextLinesProvider = { [weak self] in
            self?.host.searchContextLines ?? 2
        }
        searcher.onRun = { [weak self] run in self?.showSearchResults(run) }
        searcher.onChangeRoot = { [weak self] url in self?.changeRoot(to: url) }
    }

    /// The surface first, so a panel opens over the place the file will appear
    /// rather than over whatever the reader was looking at.
    public func presentPicker() {
        host.showFilesSurface()
        FilePickerPresenter.shared.present()
    }

    public func presentSearcher() {
        host.showFilesSurface()
        FileSearchPresenter.shared.present()
    }

    /// Arriving at Files with nothing open.
    ///
    /// An empty strip has exactly one useful next action, so it offers it rather
    /// than making a reader find the `+`. Tied to *arriving* rather than to the
    /// strip being empty, so a launch that restores onto an empty Files tab does
    /// not greet the reader with a modal they did not ask for.
    public func offerPickerOnArrival() {
        guard currentSet.isEmpty else { return }
        FilePickerPresenter.shared.present()
    }

    /// Leaving Files takes the panels with it.
    ///
    /// A menu key equivalent is matched ahead of the responder chain entirely,
    /// so the view-switch chords reach the menu even while a panel holds the
    /// keyboard. Without this a panel is left floating over a surface it cannot
    /// open a file into.
    public func dismissPanels() {
        if FilePickerPresenter.shared.isPresented {
            FilePickerPresenter.shared.dismiss()
        }
        if FileSearchPresenter.shared.isPresented {
            FileSearchPresenter.shared.dismiss()
        }
    }

    // MARK: - Opening

    /// Open a file, or hand it to the system when this reader cannot show it.
    ///
    /// The three failures are answered differently because a reader needs a
    /// different thing from each:
    ///
    /// - **Not text.** An image renders here; anything else binary does not, and
    ///   the honest answer is the application that does understand it. Opening
    ///   it externally is visible — something happens — where an alert saying
    ///   "this is binary" would be a dialog in place of the file.
    /// - **Too large.** Same answer, same reason: the cap exists to keep a
    ///   reader from waiting on a page that will not be usable, not to refuse
    ///   them the file.
    /// - **Unreadable.** Nothing to hand over — missing, or refused by the
    ///   filesystem — so this beeps and stays put.
    public func open(url: URL) {
        let set = currentSet
        do {
            try set.open(url: url)
            persist(set)
        } catch ReaderFile.LoadFailure.unreadable {
            NSSound.beep()
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    /// Select a path that is already open, or open it.
    ///
    /// The idempotence lives here rather than in a caller, so a second place
    /// deciding whether a file is open cannot come to a different answer than
    /// this one.
    public func selectOrOpen(path: String) {
        let set = currentSet
        host.showFilesSurface()
        if let existing = set.tabs.tab(forPath: path) {
            set.select(id: existing.id)
            persist(set)
        } else {
            open(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: - The strip

    public func select(id: FileTab.ID) {
        let set = currentSet
        set.select(id: id)
        persist(set)
    }

    /// Change one tab's remembered reader state — where a find query and a
    /// scroll position land.
    ///
    /// Persisted, because the whole reason they live on the tab rather than in
    /// the web view is that one reader is rebuilt per switch and cannot remember
    /// anything itself.
    public func updateTab(id: FileTab.ID, _ change: (inout FileTab) -> Void) {
        let set = currentSet
        set.updateTab(id: id, change)
        persist(set)
    }

    public func move(id: FileTab.ID, toRow row: Int, at index: Int) {
        let set = currentSet
        set.move(id: id, toRow: row, at: index)
        persist(set)
    }

    /// Take the arrangement a drag ended on, and write it down once — which is
    /// also what keeps this from persisting six times while a tab is dragged
    /// past six others.
    public func rearrange(to arrangement: [[FileTab.ID]]) {
        let set = currentSet
        set.rearrange(to: arrangement)
        persist(set)
    }

    /// Close a tab, asking first when it carries notes.
    ///
    /// The question is asked here rather than in the strip, because the strip is
    /// a view and a sheet is not its business — and because the answer is a
    /// mutation only this object is allowed to make.
    public func close(id: FileTab.ID) {
        let set = currentSet
        guard let tab = set.tabs.tabs.first(where: { $0.id == id }) else {
            return
        }
        let count = set.noteCount(forPath: tab.path)
        guard count > 0, let window = SheetAlert.hostWindow() else {
            discardTab(id: id)
            return
        }
        FileConfirmations.confirmCloseFile(
            in: window,
            fileName: tab.url.lastPathComponent,
            count: count,
            onDiscard: { [weak self] in self?.discardTab(id: id) }
        )
    }

    /// Close without asking. The confirmed path and the nothing-to-lose path
    /// both end here, so there is one place that closes a tab.
    private func discardTab(id: FileTab.ID) {
        let set = currentSet
        set.close(id: id)
        persist(set)
    }

    /// ⌘W on the Files surface.
    ///
    /// **Beeps on an empty strip rather than doing nothing, and the menu item
    /// stays enabled there.** That is what keeps ⌘W from falling through and
    /// closing the window: a reader whose muscle memory says "close this file"
    /// must not lose the window because the strip happened to be empty. Stated
    /// here once, so no host can implement it differently.
    public func closeSelected() {
        guard let id = currentSet.tabs.selectedID else {
            NSSound.beep()
            return
        }
        close(id: id)
    }

    /// Read a file from disk again, asking first when it carries notes.
    ///
    /// The one action that unfreezes content while a tab stays open, and the
    /// only way a reader sees an agent's edits without closing and reopening.
    /// Its notes cannot come with it — they quote lines the reread replaces — so
    /// the question is asked in those terms rather than as a bare confirmation.
    public func reload(id: FileTab.ID) {
        let set = currentSet
        guard let tab = set.tabs.tabs.first(where: { $0.id == id }) else {
            return
        }
        let count = set.noteCount(forPath: tab.path)
        guard count > 0, let window = SheetAlert.hostWindow() else {
            performReload(id: id)
            return
        }
        FileConfirmations.confirmReloadFile(
            in: window,
            fileName: tab.url.lastPathComponent,
            count: count,
            onDiscard: { [weak self] in self?.performReload(id: id) }
        )
    }

    /// A failed reread beeps and changes nothing: the tab, its content and its
    /// notes are all still there, which is the right outcome for a file that has
    /// just been deleted or made unreadable under the reader.
    private func performReload(id: FileTab.ID) {
        do {
            try currentSet.reload(id: id)
        } catch {
            NSSound.beep()
        }
    }

    /// Beeps on an empty stack, and on a file that has since stopped opening —
    /// in both cases nothing appears, so something has to say so.
    public func reopenLastClosed() {
        let set = currentSet
        do {
            guard try set.reopenLastClosed() != nil else {
                NSSound.beep()
                return
            }
            persist(set)
        } catch {
            NSSound.beep()
        }
    }

    public func selectPreviousFile() { step { $0.selectPrevious() } }
    public func selectNextFile() { step { $0.selectNext() } }

    /// ⌘H / ⌘L — the innermost tabbed thing on this surface.
    ///
    /// The picker's two modes while its card is up, the file strip otherwise.
    /// **Innermost surface wins**, which is the rule Escape already follows
    /// here: the card is anchored over the strip, so while a reader is looking
    /// at it the tabs they mean are its own. Stepping the strip underneath
    /// instead moves a selection they cannot see, behind a card they are typing
    /// into.
    ///
    /// Two modes, so previous and next name them rather than cycling — with a
    /// pair, "the one before" and "the one after" are the same key pressed
    /// twice, and a reader who wanted Browse should reach it with either.
    public func selectPreviousInnerTab() {
        if FilePickerPresenter.shared.isPresented {
            FilePickerPresenter.shared.selectMode(.search)
        } else {
            selectPreviousFile()
        }
    }

    public func selectNextInnerTab() {
        if FilePickerPresenter.shared.isPresented {
            FilePickerPresenter.shared.selectMode(.browse)
        } else {
            selectNextFile()
        }
    }
    public func selectPreviousRow() { step { $0.selectPreviousRow() } }
    public func selectNextRow() { step { $0.selectNextRow() } }

    private func step(_ move: (FileSet) -> Void) {
        let set = currentSet
        move(set)
        persist(set)
    }

    public func changeRoot(to url: URL) {
        let set = currentSet
        set.changeRoot(to: url)
        persist(set)
    }

    // MARK: - What a host's menu asks

    public var hasClosedFiles: Bool { !currentSet.closedTabs.isEmpty }

    /// Whether the strip has more than one row, which is what the row pair needs
    /// to be worth offering. One row is not a thing to step between.
    public var hasMultipleRows: Bool { currentSet.tabs.rows.count > 1 }

    /// Whether the previous- and next-file keystrokes have anywhere to go.
    ///
    /// Per direction, and asked of the whole order rather than of the selected
    /// tab's row. One answer for both — "does this tab have a neighbour in its
    /// row" — disabled the previous-file key on the lone tab of a row, and a
    /// disabled key equivalent is a system beep rather than nothing happening.
    /// That question was right while a step stopped at a row's end and wrong the
    /// moment steps began crossing.
    public var canSelectPreviousFile: Bool { currentSet.canSelectPrevious }
    public var canSelectNextFile: Bool { currentSet.canSelectNext }

    public var hasFileOpen: Bool { currentSet.selectedPath != nil }

    /// The host's composer bindings, forwarded so the view has one thing to ask
    /// rather than two.
    public var textEntryPayload: [String: [[String: Any]]]? {
        host.textEntryPayload
    }
}
