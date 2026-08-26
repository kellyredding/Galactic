import Combine
import Foundation

/// One browsing context: a root, the files open under it, and the notes on them.
///
/// The engine's pieces are values — a strip model, a closed stack, a note store,
/// a frozen file. This is the object that holds one of each and keeps them
/// agreeing, which is the part every host would otherwise write for itself:
/// closing a tab has to push the closed stack, drop that file's notes and
/// release its frozen content, and a host that remembered two of those three
/// leaks a note onto a file nobody has open.
///
/// **Frozen content lives here rather than in the reader.** A single reader is
/// rebuilt on every file switch, so anything the reader holds is gone the moment
/// the reader points somewhere else — and the whole render policy rests on the
/// content being what was read at open, not what is on disk now. Holding it here
/// means switching away and back shows the same bytes the notes quote.
///
/// Not actor-isolated, matching `AgentInbox` and both hosts: this is a plain
/// `ObservableObject` driving SwiftUI from the main queue. See that type for the
/// longer argument.
public final class FileSet: ObservableObject {

    /// Which application context this set belongs to — a session id in Galaxy,
    /// a constant in Assist Ant. Opaque here on purpose: nothing in this file
    /// interprets it, and the day it means something else it can.
    public let ownerID: String

    /// What a reader calls this set. One per owner today, so there is nothing to
    /// tell apart yet; named sets are a later phase and this is the field they
    /// will use.
    @Published public private(set) var name: String

    /// Where browsing starts, and what a tab's label is relative to.
    @Published public private(set) var root: URL

    @Published public private(set) var tabs: FileTabStripModel

    @Published public private(set) var closedTabs: ClosedTabStack

    /// In memory, and nowhere else. See `FileNoteStore`.
    @Published public private(set) var notes: FileNoteStore

    /// Files opened in this set, most recent first — what the picker offers once
    /// the closed stack runs out.
    @Published public private(set) var recentFiles: [URL]

    /// What the whole review is about, and whether its field is open.
    ///
    /// Set-wide, and that is the entire reason it lives here: the send bar
    /// carrying it is drawn inside whichever file's page is on screen, so a
    /// comment stored per file would reappear on the file that happened to be
    /// showing when it was typed and vanish everywhere else. `ComposerStateMerge`
    /// is what separates it back out of the page's rescued blob.
    @Published public private(set) var overallComment: String = ""
    @Published public private(set) var overallExpanded: Bool = false

    /// Which tab the page currently on screen was built for.
    ///
    /// Not the same as the selected tab, and the difference is the point: a
    /// rescue arrives from the page being replaced, so filing it needs to know
    /// what that page *was*. Selection has already moved on by then.
    private var renderedTabID: FileTab.ID?

    /// The content of every open file, as it was when it was opened.
    ///
    /// Not `@Published`: a whole file's text arriving in a publisher would push
    /// every observer through a view update for something none of them reads
    /// directly. Readers ask for it by path at build time.
    private var frozen: [String: ReaderFile]

    /// How much history is kept. Larger than anything presented, because the
    /// record is cheap and the presentation cap is the thing that changes.
    public static let recentLimit = 60

    public init(
        ownerID: String,
        name: String = "Default",
        root: URL
    ) {
        self.ownerID = ownerID
        self.name = name
        self.root = root
        tabs = FileTabStripModel()
        closedTabs = ClosedTabStack()
        notes = FileNoteStore()
        recentFiles = []
        frozen = [:]
    }

    // MARK: - Reading

    public var selectedTab: FileTab? { tabs.selected }

    /// The frozen content behind one open path.
    public func file(forPath path: String) -> ReaderFile? { frozen[path] }

    /// The frozen content behind whichever tab is showing.
    public var selectedFile: ReaderFile? {
        guard let path = tabs.selected?.path else { return nil }
        return frozen[path]
    }

    public var isEmpty: Bool { tabs.isEmpty }

    /// What the badge on one tab shows.
    public func noteCount(forPath path: String) -> Int {
        notes.count(forPath: path)
    }

    /// What the send bar shows — the whole review, not the file on screen.
    public var totalNoteCount: Int { notes.totalCount }

    /// Every open file's frozen content, in tab order.
    ///
    /// What `AgentReviewComposer` takes: the order blocks appear in a review is
    /// the order the tabs sit in, so a reader reading their own review reads it
    /// in the order they arranged. Files whose content is somehow missing are
    /// skipped rather than faulted — a review is worth sending without one file
    /// in it.
    public var orderedFiles: [ReaderFile] {
        tabs.tabs.compactMap { frozen[$0.path] }
    }

    // MARK: - Opening and closing

    /// Open a file, reading and freezing it.
    ///
    /// Throws what `ReaderFile` throws, unread: a host answers a binary file by
    /// handing it to the system and an oversized one by saying by how much, and
    /// flattening those into one failure here would take that choice away.
    ///
    /// A file already open is selected rather than re-read. That is what keeps
    /// the content frozen across a reader who reaches the same file twice — a
    /// second read would replace the bytes their notes are quoting.
    @discardableResult
    public func open(url: URL) throws -> FileTab {
        if let existing = tabs.tab(forPath: url.path) {
            tabs.select(id: existing.id)
            recordRecent(url)
            return existing
        }

        let file = try ReaderFile.load(url: url)
        frozen[url.path] = file
        let tab = tabs.open(url: url)

        // It is open, so it is no longer closed. Left in, the history would
        // offer a file whose tab is on screen.
        closedTabs.remove(url: url)
        recordRecent(url)
        return tab
    }

    /// Close a tab, and take its notes and its content with it.
    ///
    /// Returns the stacked entry so a caller can say what it just did. The three
    /// effects are one operation on purpose — a host that pushed the stack and
    /// forgot to drop the notes would keep a review alive on a file the reader
    /// has closed, and nothing would report it.
    @discardableResult
    public func close(id: FileTab.ID) -> ClosedTabStack.Entry? {
        guard let position = tabs.position(of: id) else { return nil }
        guard let closed = tabs.close(id: id) else { return nil }

        closedTabs.push(
            url: closed.url, row: position.row, column: position.column
        )
        notes.drop(path: closed.path)
        frozen[closed.path] = nil
        return ClosedTabStack.Entry(
            url: closed.url, row: position.row, column: position.column
        )
    }

    /// Reopen the most recently closed file, into the row it came from.
    ///
    /// Nil when the stack is empty — the caller beeps. A file that has since
    /// become unopenable throws, and is *not* put back on the stack: it would
    /// then be the first thing offered again, and offering it again is offering
    /// the same failure.
    @discardableResult
    public func reopenLastClosed() throws -> FileTab? {
        guard let entry = closedTabs.pop() else { return nil }

        let file = try ReaderFile.load(url: entry.url)
        frozen[entry.url.path] = file
        let tab = tabs.reopen(
            url: entry.url, preferredRow: entry.row,
            preferredColumn: entry.column
        )
        recordRecent(entry.url)
        return tab
    }

    /// Read a file again, replacing what was frozen at open.
    ///
    /// The one way content is ever unfrozen while a tab stays open. Everything
    /// else about this feature assumes the bytes cannot move underneath a reader:
    /// a note quotes lines as they were read, and `FileDriftCheck` reports at
    /// send time that the file has moved on rather than trying to follow it.
    ///
    /// **Notes on the file go.** They are fastened to line numbers in the
    /// document being replaced, and a fresh read is a different document — the
    /// quote would survive while the line it cites moved, which is worse than
    /// losing it, because it looks right. The caller asks first;
    /// `FileConfirmations.confirmReloadFile` is that question.
    ///
    /// Scroll offset and the find query stay, because they are about where the
    /// reader was rather than about what the content said, and landing back at
    /// the top of a file you were halfway down is its own small loss. Throws when
    /// the file has stopped being readable, leaving the tab and its frozen
    /// content exactly as they were — a failed reread must not empty the tab.
    @discardableResult
    public func reload(id: FileTab.ID) throws -> ReaderFile? {
        guard let tab = tabs.tabs.first(where: { $0.id == id }) else {
            return nil
        }
        let fresh = try ReaderFile.load(url: tab.url)
        frozen[tab.path] = fresh
        notes.drop(path: tab.path)
        // The composer goes with the notes: a half-written card names lines that
        // may no longer be there.
        tabs.update(id: id) { $0.composerState = nil }
        return fresh
    }

    public func select(id: FileTab.ID) { tabs.select(id: id) }

    public func selectTab(forPath path: String) {
        guard let tab = tabs.tab(forPath: path) else { return }
        tabs.select(id: tab.id)
    }

    // MARK: - Rearranging and navigating

    /// Take the whole arrangement a drag ended on.
    public func rearrange(to arrangement: [[FileTab.ID]]) {
        tabs.rearrange(to: arrangement)
    }

    public func move(id: FileTab.ID, toRow row: Int, at index: Int) {
        tabs.move(id: id, toRow: row, at: index)
    }

    public func selectNext() { tabs.selectNext() }
    public func selectPrevious() { tabs.selectPrevious() }

    /// Whether the next or previous file keystroke has anywhere to go, so a host
    /// can enable its menu item per direction rather than for both at once.
    public var canSelectNext: Bool { tabs.canSelectNext }
    public var canSelectPrevious: Bool { tabs.canSelectPrevious }
    public func selectNextRow() { stepRow(by: 1) }
    public func selectPreviousRow() { stepRow(by: -1) }

    /// The strip's measured width, told to the set by the strip.
    ///
    /// Not `@Published`: nothing renders differently for knowing it, and
    /// republishing on every window resize would be a redraw for no reason.
    /// Navigation is the only thing that reads it, once per keystroke.
    public var stripWidth: CGFloat = 0

    /// Up or down a row, landing under where the current tab actually is.
    ///
    /// Falls back to the model's column-for-column step before the strip has
    /// been measured — the first keystroke of a session, when there is no
    /// geometry to consult and an index is the only honest answer.
    private func stepRow(by delta: Int) {
        guard stripWidth > 0, let id = tabs.selectedID,
            let position = tabs.position(of: id)
        else {
            delta > 0 ? tabs.selectNextRow() : tabs.selectPreviousRow()
            return
        }
        let target = position.row + delta
        guard tabs.rows.indices.contains(target) else { return }

        let column = FileTabRowNavigation.column(
            movingFrom: position.column,
            in: widths(ofRow: position.row),
            to: widths(ofRow: target),
            spacing: FileTabRowFit.Metrics.standard.spacing,
            leading: FileTabRowFit.Metrics.standard.padding
        )
        guard tabs.rows[target].indices.contains(column) else { return }
        tabs.select(id: tabs.rows[target][column].id)
    }

    /// What the strip drew that row as, through the same fit it drew with.
    private func widths(ofRow row: Int) -> [CGFloat] {
        FileTabRowFit.fit(
            row: tabs.rows[row],
            root: root,
            siblings: tabs.tabs.map(\.url),
            noteCount: { [weak self] in self?.noteCount(forPath: $0.path) ?? 0 },
            stripWidth: stripWidth
        )
        .map(\.width)
    }

    // MARK: - The root

    /// Change where browsing starts.
    ///
    /// Open tabs stay open, including any now outside the root — they keep an
    /// absolute label, which `FileTabLabel` already answers. Closing them would
    /// make changing the root a way to lose work.
    public func changeRoot(to url: URL) {
        guard url.path != root.path else { return }
        root = url
    }

    public func rename(to newName: String) {
        guard !newName.isEmpty, newName != name else { return }
        name = newName
    }

    // MARK: - Per-tab state

    /// Record something the reader left in the tab that is showing.
    ///
    /// The scroll offset, the find query, the rescued composer — all of it is
    /// per-file state a rebuild would otherwise lose. See `FileTab`.
    public func updateSelectedTab(_ mutate: (inout FileTab) -> Void) {
        guard let id = tabs.selectedID else { return }
        tabs.update(id: id, mutate)
    }

    public func updateTab(id: FileTab.ID, _ mutate: (inout FileTab) -> Void) {
        tabs.update(id: id, mutate)
    }

    // MARK: - Notes

    /// The store is `private(set)` and these are why: every note a reader writes
    /// arrives through the set, so there is exactly one object that knows how a
    /// note and its file relate. A host holding the store directly could add a
    /// note to a path it has no tab for, and nothing would report it.

    @discardableResult
    public func addNote(
        filePath: String,
        startLine: Int32,
        endLine: Int32,
        lineContent: String,
        content: String,
        createdAt: String
    ) -> FileNote? {
        // Refused rather than stored for a file this set does not have open. A
        // note is anchored to frozen content, and there is none to anchor to.
        guard frozen[filePath] != nil else { return nil }

        return notes.add(
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            lineContent: lineContent,
            content: content,
            createdAt: createdAt
        )
    }

    public func updateNote(id: Int64, content: String) {
        notes.update(id: id, content: content)
    }

    public func deleteNote(id: Int64) {
        notes.delete(id: id)
    }

    /// The two the page asks for, which names a note by its per-file number.
    ///
    /// Resolved to an id here rather than the store growing number-keyed
    /// mutators: ids are what the store is built on, and a second addressing
    /// scheme reaching into it is a second thing to keep consistent. A number
    /// with no note — a card the page still shows but the store has dropped —
    /// does nothing, which is the right answer to a notification about
    /// something already gone.

    public func updateNote(filePath: String, number: Int32, content: String) {
        guard let note = notes.note(forPath: filePath, number: number) else {
            return
        }
        notes.update(id: note.id, content: content)
    }

    public func deleteNote(filePath: String, number: Int32) {
        guard let note = notes.note(forPath: filePath, number: number) else {
            return
        }
        notes.delete(id: note.id)
    }

    public func setOverallComment(_ text: String, expanded: Bool) {
        overallComment = text
        overallExpanded = expanded
    }

    // MARK: - The review

    /// The message an agent would receive right now, or nil when there is
    /// nothing to send.
    ///
    /// Composing and clearing are **deliberately separate calls.** A single
    /// take-and-empty would be atomic and would lose a review whenever the
    /// send was refused — and refusal is a real state here, since the target
    /// can decline a prompt the agent is not ready to read. Notes surviving a
    /// refused send is the failure worth having.
    public func composeReview() -> String? {
        let text = AgentReviewComposer.compose(
            overallComment: overallComment,
            files: orderedFiles,
            notes: notes,
            root: root
        )
        return text.isEmpty ? nil : text
    }

    /// The review landed. Everything it carried goes, including the comment.
    ///
    /// The comment goes too because it described *that* review. Left behind, it
    /// would lead the next one — a summary of work already sent, sitting above
    /// unrelated notes.
    public func clearReview() {
        notes.clear()
        overallComment = ""
        overallExpanded = false
    }

    /// Everything goes — the review was sent.
    public func clearNotes() {
        notes.clear()
    }

    // MARK: - The composer across a rebuild

    /// File what the outgoing page was holding, and say what the incoming one
    /// should be given.
    ///
    /// This is the whole reason switching files needs no warning. The page is
    /// destroyed on every switch, so the rescue is the only thing carrying a
    /// half-written note across one — and the blob mixes two lifetimes, which is
    /// why it cannot simply be stored as it arrives. The card state belongs to
    /// the file being left; the send bar's summary belongs to the review, which
    /// spans every file in the set.
    ///
    /// A rescue that cannot be read costs the composer and never the switch: both
    /// directions degrade to nil rather than throwing, and a page that reported
    /// no comment leaves whatever the set already held rather than clearing it —
    /// a failed rescue is not a reader deleting their summary.
    @discardableResult
    public func handOffComposer(
        rescued: String?, to incoming: FileTab.ID?
    ) -> String? {
        if let rescued, let outgoing = renderedTabID {
            if let lifted = ComposerStateMerge.overallComment(from: rescued) {
                overallComment = lifted.text
                overallExpanded = lifted.expanded
            }
            // Stored with the set-wide half taken out, so the same summary
            // cannot come back from two places at once.
            let perFile = ComposerStateMerge.merged(
                perFile: rescued, overallComment: "", expanded: false
            )
            tabs.update(id: outgoing) { $0.composerState = perFile }
        }

        renderedTabID = incoming

        guard let incoming,
            let tab = tabs.tabs.first(where: { $0.id == incoming })
        else { return nil }

        return ComposerStateMerge.merged(
            perFile: tab.composerState,
            overallComment: overallComment,
            expanded: overallExpanded
        )
    }

    /// Store the outgoing page's scroll position and answer with the incoming
    /// page's.
    ///
    /// The mirror of `handOffComposer`, and deliberately not folded into it: the
    /// composer rescue answers nothing for a page the annotation layer declined
    /// to install on, and those pages scroll too.
    ///
    /// **Called before `handOffComposer`, which is what moves `renderedTabID`.**
    /// Reading it after would name the file arriving rather than the one leaving
    /// and store the position onto the wrong tab.
    @discardableResult
    public func handOffScroll(rescued: Double?, to incoming: FileTab.ID?)
        -> Double
    {
        if let rescued, rescued > 0, let outgoing = renderedTabID {
            tabs.update(id: outgoing) { $0.scrollOffset = rescued }
        }
        guard let incoming,
            let tab = tabs.tabs.first(where: { $0.id == incoming })
        else { return 0 }
        return tab.scrollOffset
    }

    // MARK: - Persistence

    /// The open files, as rows, for a host to persist.
    ///
    /// Rows rather than a flat list, because the arrangement is the reader's.
    /// Persisting the files alone and letting them re-pack on the way back in
    /// would quietly undo every row a reader made — the same wrong answer as
    /// reflowing on close, arriving a restart later.
    public var openPathRows: [[String]] {
        tabs.rows.map { $0.map(\.path) }
    }

    public var selectedPath: String? { tabs.selected?.path }

    /// Rebuild a set from what a host persisted.
    ///
    /// Best effort by design. A path that will not open is dropped and the rest
    /// still come back: between two launches a file gets deleted, renamed,
    /// replaced by a build step with something binary, or grown past the cap,
    /// and none of those is a reason to lose the other nine tabs. Returns the
    /// paths that did not make it, so a host can say so if it wants to.
    ///
    /// **Notes are never restored**, here or anywhere. There is nothing to
    /// restore them from.
    @discardableResult
    public func restore(
        openPathRows rows: [[String]],
        selectedPath: String? = nil
    ) -> [String] {
        var dropped: [String] = []
        var restored: [[URL]] = []

        for row in rows {
            var urls: [URL] = []
            for path in row {
                let url = URL(fileURLWithPath: path)
                guard let file = try? ReaderFile.load(url: url) else {
                    dropped.append(path)
                    continue
                }
                frozen[path] = file
                urls.append(url)
                recordRecent(url)
            }
            if !urls.isEmpty { restored.append(urls) }
        }

        tabs.restore(rows: restored)
        if let selectedPath { selectTab(forPath: selectedPath) }
        return dropped
    }

    // MARK: - History

    /// Most recent first, deduped, capped. Every open goes through here — a
    /// fresh open, a reopen, and a restore — because "recent" means *reached*
    /// rather than newly discovered.
    private func recordRecent(_ url: URL) {
        recentFiles.removeAll { $0.path == url.path }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > Self.recentLimit {
            recentFiles.removeLast(recentFiles.count - Self.recentLimit)
        }
    }

    /// Recent files that are not currently open, newest first.
    ///
    /// Open files are excluded here because whether a file has a tab is this
    /// object's knowledge, and a caller that had to intersect the two itself
    /// would be a second place that knows what open means.
    ///
    /// **The closed stack is deliberately not subtracted.** A closed file is in
    /// both lists, and which one shows it is a question only the picker can
    /// answer — it is the thing displaying both, in a chosen order, so the
    /// de-duplication is part of composing that display rather than a property
    /// of either list. Subtracting it here would also make this always empty
    /// in-session, since the only way a file leaves this set's tabs is by being
    /// closed.
    public func presentedRecents(limit: Int = 20) -> [URL] {
        let openPaths = Set(tabs.tabs.map(\.path))
        return recentFiles
            .filter { !openPaths.contains($0.path) }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
