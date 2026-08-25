import AppKit
import Foundation
import WebKit

// The note layer, the review, the escape ladder and the search-results path.
//
// None of this varies per host. What used to make it look host-shaped was that
// its two host-facing moments — where a review goes, and where the reply appears
// — sit at the end of one method, and the whole file followed them into the
// application.
extension FilesSurface {

    // MARK: - Notes

    /// Answer one message from the page.
    ///
    /// Every mutation ends by telling the page two things: the card it just made
    /// or changed, and the set-wide count on the send bar. Neither is optional —
    /// the page latches a form in its submitting state until the echo arrives,
    /// and the bar's count is pushed rather than derived because a note on
    /// another file changes it without anything in this page moving.
    ///
    /// Messages this surface cannot produce are named rather than defaulted, so
    /// a shape added to the engine has to be answered here instead of being
    /// silently dropped. Source anchors by line, so the line-range case is the
    /// only create a text file emits; the diff, row, block and whole shapes
    /// belong to readers this surface does not host.
    public func handle(_ message: AnnotationMessage, webView: WKWebView?) {
        let set = currentSet
        guard let tab = set.selectedTab else { return }

        switch message {
        case .create(let startLine, let endLine, let content):
            createNote(
                startLine: startLine,
                endLine: endLine,
                content: content,
                path: tab.path,
                set: set,
                webView: webView
            )

        case .update(let number, let content):
            set.updateNote(
                filePath: tab.path, number: number, content: content
            )
            guard
                let note = set.notes.note(forPath: tab.path, number: number)
            else { return }
            evaluate(
                "AnnotationManager.annotationUpdated("
                    + fileNoteEchoPayload(note) + ")",
                in: webView
            )

        case .delete(let number):
            set.deleteNote(filePath: tab.path, number: number)
            evaluate(
                "AnnotationManager.annotationDeleted(\(number))", in: webView
            )
            pushCount(set: set, to: webView)

        case .reviewWithClaude(let comment):
            send(comment: comment, set: set, webView: webView)

        case .createDiffRange, .createRowRange, .createBlockRange,
            .createWhole, .confirmDragReplace, .setViewed:
            break
        }
    }

    private func createNote(
        startLine: Int32,
        endLine: Int32,
        content: String,
        path: String,
        set: FileSet,
        webView: WKWebView?
    ) {
        guard
            let note = set.addNote(
                filePath: path,
                startLine: startLine,
                endLine: endLine,
                lineContent: quotedLines(
                    from: path, startLine: startLine, endLine: endLine, set: set
                ),
                content: content,
                createdAt: Self.timestamp()
            )
        else {
            // Refused, which means the file is no longer frozen here. Nothing to
            // echo, so the form is released by hand — left alone it stays
            // latched in its submitting state with no way back, which is the one
            // failure the page cannot recover from on its own.
            evaluate(
                "AnnotationManager.submitting = false;"
                    + "AnnotationManager.dismissForm()",
                in: webView
            )
            return
        }

        evaluate(
            "AnnotationManager.annotationCreated("
                + fileNoteEchoPayload(note) + ")",
            in: webView
        )
        pushCount(set: set, to: webView)
    }

    /// The lines as they read when the note was written — what a review quotes.
    ///
    /// Sliced from the frozen content rather than from disk, which is the whole
    /// point of freezing: the agent may have rewritten the file since the reader
    /// selected these lines, and the quote has to be what they were looking at.
    private func quotedLines(
        from path: String, startLine: Int32, endLine: Int32, set: FileSet
    ) -> String {
        guard let file = set.file(forPath: path) else { return "" }
        let lines = file.content.components(separatedBy: "\n")
        let start = max(Int(startLine) - 1, 0)
        let end = min(Int(endLine), lines.count)
        guard start < end else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    /// What the send bar reports: every note in the set, not the file on screen.
    private func pushCount(set: FileSet, to webView: WKWebView?) {
        evaluate(
            "window.GalaxySendBar.update(\(set.totalNoteCount))", in: webView
        )
    }

    func evaluate(_ js: String, in webView: WKWebView?) {
        webView?.evaluateJavaScript(js)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    // MARK: - Sending

    /// Compose the review, hand it to the host's agent, and empty the set.
    ///
    /// **Sent unconditionally, even with no agent running.** A scrollback pane
    /// can refuse in that state because its notes are still on screen
    /// afterwards. These are not — the reader has pressed the one button that
    /// destroys them — so refusing would mean either losing the review or
    /// leaving the press to do nothing visible. Both hosts queue rather than
    /// refuse, and the queue is what makes that safe.
    ///
    /// The comment is taken from the press rather than from the set, because the
    /// bar carries whatever was typed into it at that instant, which may be
    /// newer than the last rescue.
    private func send(comment: String, set: FileSet, webView: WKWebView?) {
        set.setOverallComment(comment, expanded: false)

        guard let review = set.composeReview() else {
            // The bar refuses to fire on an empty count, so this is a press that
            // raced a deletion. Put the count back rather than leaving a bar
            // that has reported zero and sent nothing.
            pushCount(set: set, to: webView)
            return
        }

        currentHost.deliverReview(review, forOwner: set.ownerID)
        set.clearReview()
        pushCount(set: set, to: webView)

        // The page on screen is holding cards for notes that have just left, and
        // it has no way to know: every other file re-renders when the reader
        // arrives at it, because arriving rebuilds the page, but the file they
        // were looking at when they pressed send is the one page that does not
        // get rebuilt. An empty set is sent rather than withheld — that is how
        // this page is told its last card is gone. An empty array, not an empty
        // object: the page assigns it straight onto its annotation list and then
        // iterates it.
        evaluate("AnnotationManager.refreshAnnotationData([], {})", in: webView)

        // Where the answer will appear. A reader who has just asked a question
        // is looking for the reply, not for the file.
        currentHost.showAgentSurface()
    }

    // MARK: - Escape

    /// Unwind one layer of the reader's composer.
    ///
    /// Asked of the page rather than decided here, because only the page knows
    /// what is open: an emoji popup over a textarea, an expanded summary on the
    /// send bar, an edit with or without changes, an expanded card, a form with
    /// or without text. Asking changes nothing, so each answer names the action
    /// it wants — including the two that have to be confirmed before they
    /// destroy typing.
    public func handleEscape(webView: WKWebView?) {
        guard let webView else { return }
        webView.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined' "
                + "? AnnotationManager.escapeContext() : 'close'"
        ) { [weak self] result, _ in
            guard let self, let context = result as? String else { return }
            switch context {
            case "emojiPopup":
                self.evaluate(
                    "AnnotationManager.dismissEmojiPopup()", in: webView
                )
            case "overallComment":
                self.evaluate(
                    "AnnotationManager.collapseOverallComment()", in: webView
                )
            case "editingDirty":
                self.confirmDiscard(
                    prompt: FileConfirmations.confirmDiscardNoteEdit,
                    then: "AnnotationManager.cancelEdit()",
                    in: webView
                )
            case "editingClean":
                self.evaluate("AnnotationManager.cancelEdit()", in: webView)
            case "expanded":
                self.evaluate(
                    "AnnotationManager.collapseExpanded()", in: webView
                )
            case "formHasText":
                self.confirmDiscard(
                    prompt: FileConfirmations.confirmDiscardNoteForm,
                    then: "AnnotationManager.dismissForm()",
                    in: webView
                )
            case "formVisible":
                self.evaluate("AnnotationManager.dismissForm()", in: webView)
            default:
                // Nothing open. Unlike an artifact reader there is no reader to
                // close behind the cards — the strip and the file stay — so the
                // outermost layer is where Escape stops.
                break
            }
        }
    }

    /// Ask, then run the discard in the page. Cancelling does nothing at all,
    /// which leaves the caret where the sheet took it from.
    private func confirmDiscard(
        prompt: (NSWindow, @escaping () -> Void, @escaping () -> Void) -> Void,
        then js: String,
        in webView: WKWebView
    ) {
        guard let window = SheetAlert.hostWindow() else {
            // No window to ask in, so the destructive answer is not given on the
            // reader's behalf — the text stays and Escape did nothing.
            return
        }
        prompt(window, { [weak self] in self?.evaluate(js, in: webView) }, {})
    }

    // MARK: - Search results

    /// Where a set's results file lives.
    ///
    /// Under `~/.galactic` because `.galactic` is in the index's default skip
    /// list, so the results can never be found by the search that wrote them. A
    /// host rooted at home would turn up its own results anywhere else under
    /// `~`, which is why this is not left to one.
    public static func searchResultsURL(owner: String) -> URL {
        FileIndexPaths.root
            .appendingPathComponent("search")
            .appendingPathComponent(owner)
            .appendingPathComponent("Find Results")
    }

    /// The run behind the results tab, if this path is it.
    public func searchRun(forPath path: String, owner: String) -> FileSearchRun?
    {
        guard owner == searchRunOwner,
            path == Self.searchResultsURL(owner: owner).path
        else { return nil }
        return searchRun
    }

    /// Write a run and put it on screen.
    ///
    /// One results tab per set, rewritten in place. The file is real — that is
    /// what lets the strip, the labels, reopen and persistence treat it like any
    /// other tab instead of needing a branch each.
    public func showSearchResults(_ run: FileSearchRun) {
        let set = currentSet
        searchRun = run
        searchRunOwner = set.ownerID
        let url = Self.searchResultsURL(owner: set.ownerID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // A plain-text rendering, so the file says something sensible to
            // anything that is not this reader — Copy Path then open elsewhere,
            // or a relaunch that has the file but not the run.
            try Data(FileSearchPlainText.render(run: run).utf8).write(to: url)
        } catch {
            NSSound.beep()
            return
        }

        currentHost.showFilesSurface()
        if let existing = set.tabs.tab(forPath: url.path) {
            // Reread rather than reopen: the tab is already there, and a fresh
            // read is what moves `loadedAt` and so rebuilds the page. The set's
            // own reload rather than this object's, which would ask about
            // discarding notes — a results page has no way to make one.
            try? set.reload(id: existing.id)
            set.select(id: existing.id)
            persist(set)
        } else {
            // **Not through `open(url:)`.** That taxonomy is written for a file
            // a *reader chose*, where handing an unrenderable one to the
            // application that understands it is the honest answer. This file is
            // ours and was written a line ago, so the only thing the system can
            // do with it is open a text editor over the app that was asked for a
            // search — which is what it did, when a minified line pushed the
            // page past the reader's size cap.
            do {
                try set.open(url: url)
                persist(set)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// A results page asked for a file, and possibly a line in it.
    ///
    /// The same open the picker performs, with the same failure taxonomy — this
    /// is another way to reach a file, not a second way to open one.
    public func openSearchHit(path: String, line: Int?) {
        if let line { pendingJump = (path: path, line: line) }
        open(url: URL(fileURLWithPath: path))
    }

    /// Take the pending jump if it belongs to this file.
    ///
    /// Consumed rather than left, so a later rebuild of the same file — a theme
    /// change, a reread — restores the reader's scroll instead of jumping again
    /// to a line they have since scrolled away from.
    public func consumePendingJump(forPath path: String) -> Int? {
        guard let pendingJump, pendingJump.path == path else { return nil }
        self.pendingJump = nil
        return pendingJump.line
    }

}
