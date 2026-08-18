import AppKit

/// The four moments a reader is asked before their notes go.
///
/// Modelled on `ScrollbackConfirmations`, which exists because both hosts had
/// written the same five prompts letter for letter and one side's improvements
/// never reached the other. Same reasoning, arriving before the duplication
/// rather than after it: Galaxy will mount this surface next, and these prompts
/// are the part it would otherwise retype.
///
/// **Every detail string is a pure function, tested.** Wording is what drifts,
/// and a prompt is the one piece of a destructive path that cannot be checked by
/// exercising the path — a test that clicked Discard would be testing `NSAlert`.
/// So the sentence is separated from the sheet: the sheet is trivial and the
/// sentence is pinned.
///
/// ### What is deliberately not here
///
/// **Switching files.** The composer rescue makes a switch lossless — the card
/// goes onto the file being left and comes back when the reader returns — so
/// there is nothing to warn about, and a warning would teach a reader that
/// moving between files is dangerous when it is the ordinary thing to do.
public enum FileConfirmations {

    /// "3 notes" / "1 note". Its own function because four prompts count the
    /// same thing and a fifth will.
    static func notesPhrase(_ count: Int) -> String {
        "\(count) note\(count == 1 ? "" : "s")"
    }

    /// Why every one of these is final, in one clause.
    ///
    /// Notes are never written down — not to a database, not to a timeline, not
    /// into the window state. So unlike a scrollback review in Galaxy, which an
    /// agent's ledger still holds after the fact, there is no copy of these
    /// anywhere once the sheet is answered. A reader deciding whether to click
    /// Discard is entitled to know that rather than to assume the usual
    /// undo-somewhere exists.
    static let finality = "They are not written down anywhere, so they cannot "
        + "be recovered."

    // MARK: - Closing a file

    static func closeDetail(fileName: String, count: Int) -> String {
        "\(fileName) has \(notesPhrase(count)) that have not been sent. "
            + finality
    }

    /// Closing a tab that carries notes.
    ///
    /// Named for the file rather than counting the whole review, because closing
    /// one tab takes one file's notes and a reader with notes on four files
    /// needs to know which they are about to lose.
    public static func confirmCloseFile(
        in window: NSWindow,
        fileName: String,
        count: Int,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Close \(fileName) and discard its notes?",
            detail: closeDetail(fileName: fileName, count: count),
            onConfirm: onDiscard,
            onCancel: onCancel
        )
    }

    // MARK: - Rereading a file

    static func reloadDetail(fileName: String, count: Int) -> String {
        "\(notesPhrase(count)) on \(fileName) are fastened to the lines as "
            + "they were read. Rereading the file replaces those lines, so the "
            + "notes go with them. " + finality
    }

    /// Rereading a file the reader has annotated.
    ///
    /// The notes cannot survive it, and that is a property of the design rather
    /// than a limitation to work around: a note quotes content frozen at open,
    /// and a reread is a new document with its own line numbers. Keeping the
    /// notes would leave quotes fastened to lines that have moved.
    public static func confirmReloadFile(
        in window: NSWindow,
        fileName: String,
        count: Int,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Reread \(fileName) and discard its notes?",
            detail: reloadDetail(fileName: fileName, count: count),
            confirm: "Reread",
            onConfirm: onDiscard,
            onCancel: onCancel
        )
    }

    // MARK: - Quitting

    static func quitDetail(count: Int, fileCount: Int) -> String {
        let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
        return "You have \(notesPhrase(count)) across \(files) that have not "
            + "been sent. " + finality
    }

    /// Quitting with a review nobody has sent.
    ///
    /// Counts files as well as notes, unlike the others: at quit the reader is
    /// not looking at the strip, so the number of notes alone does not tell them
    /// how much of their afternoon this is.
    public static func confirmQuit(
        in window: NSWindow,
        count: Int,
        fileCount: Int,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Quit and discard your notes?",
            detail: quitDetail(count: count, fileCount: fileCount),
            confirm: "Quit",
            onConfirm: onDiscard,
            onCancel: onCancel
        )
    }

    // MARK: - Switching sets

    static func switchSetDetail(setName: String, count: Int) -> String {
        "\(notesPhrase(count)) in \(setName) have not been sent. Switching "
            + "sets empties them. " + finality
    }

    /// Leaving a set that still holds notes.
    ///
    /// **No caller yet, on purpose.** Sets are one-per-owner until named sets
    /// ship, so nothing can switch away from one — but the moment something can,
    /// the reader has to be asked, and the failure mode of discovering that later
    /// is a feature that silently empties a review on its first day. Written now
    /// so that phase adds a call site rather than a mechanism, and so this file
    /// holds every question the surface knows how to ask.
    public static func confirmSwitchSet(
        in window: NSWindow,
        setName: String,
        count: Int,
        onDiscard: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        SheetAlert.confirm(
            in: window,
            message: "Leave \(setName) and discard its notes?",
            detail: switchSetDetail(setName: setName, count: count),
            confirm: "Leave",
            onConfirm: onDiscard,
            onCancel: onCancel
        )
    }
}
