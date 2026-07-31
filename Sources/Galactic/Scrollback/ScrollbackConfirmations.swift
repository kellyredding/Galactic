import AppKit

/// The five things a scrollback overlay asks before losing someone's writing.
///
/// Each host had its own copy of all five, with the same wording letter for
/// letter — the sort of duplication that stays invisible until one side's
/// phrasing is improved and the other's is not. The prompts belong with the
/// surface that raises them, and four of the five need nothing from the host
/// at all: the answer is a call back into the same page.
///
/// `onCancel` is where a host restores focus. Cancelling a prompt means the
/// user wants to go on working in the thing they were warned about, and the
/// sheet has taken first responder away from it.
public extension ScrollbackOverlayView {

    /// Leaving scrollback with notes that were never sent.
    ///
    /// The only prompt whose confirm path belongs to the host: what "discard"
    /// means here is tearing the overlay down, and the host owns that.
    func confirmDiscardNotes(
        in window: NSWindow,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let count = scrollbackView.notes.count
        SheetAlert.confirm(
            in: window,
            message: "Discard scrollback notes?",
            detail: "You have \(count) unsaved "
                + "note\(count == 1 ? "" : "s"). "
                + "They will be lost if you exit scrollback.",
            onConfirm: onDiscard,
            onCancel: onCancel
        )
    }

    /// Dismissing while the note form holds text nobody has saved.
    func confirmDiscardNoteForm(
        in window: NSWindow,
        onCancel: @escaping () -> Void
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you dismiss.",
            onConfirm: { [weak self] in
                self?.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardForm()"
                )
            },
            onCancel: onCancel
        )
    }

    /// Cancelling an edit whose text has diverged from what was stored.
    func confirmDiscardNoteEdit(
        in window: NSWindow,
        onCancel: @escaping () -> Void
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to this note. "
                + "They will be lost if you cancel editing.",
            onConfirm: { [weak self] in
                self?.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.forceDiscardEdit()"
                )
            },
            onCancel: onCancel
        )
    }

    /// Sending while a comment is still open — the comment is not included,
    /// and sending is what destroys it.
    func confirmSendWithUnsavedComment(
        in window: NSWindow,
        onCancel: @escaping () -> Void
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Send without unsaved comment?",
            detail: "You have unsaved text in a comment that "
                + "won't be included. It will be lost if you send.",
            confirm: "Send",
            onConfirm: { [weak self] in
                self?.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.sendToClaude(true)"
                )
            },
            onCancel: onCancel
        )
    }

    /// Selecting different lines while the form holds text for the old ones.
    ///
    /// Needs nothing from the host: both answers are a call back into the
    /// page — take the new selection, or return to the form as it was.
    func confirmReplaceSelection(
        in window: NSWindow,
        startLine: Int,
        endLine: Int
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Discard note?",
            detail: "You have unsaved text in the note form. "
                + "It will be lost if you select different "
                + "lines.",
            onConfirm: { [weak self] in
                self?.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes"
                        + ".showSelectionToolbar("
                        + "\(startLine), \(endLine))"
                )
            },
            onCancel: { [weak self] in
                self?.scrollbackView.webView.evaluateJavaScript(
                    "ScrollbackManager.notes.focusForm()"
                )
            }
        )
    }
}
