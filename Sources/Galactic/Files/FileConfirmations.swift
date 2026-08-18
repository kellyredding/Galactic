import AppKit

/// The four moments a reader is warned before their notes go.
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

    /// One sentence for a host's own quit sheet — **not** a sheet of its own.
    ///
    /// Quitting is one decision, and a host already has a place where it is
    /// asked: Assist Ant assembles every stake into a single list of reasons and
    /// presents them together, on the argument that quitting takes the agent and
    /// the notes at the same time. A second sheet arriving in sequence would ask
    /// a reader to answer the same question twice and let them answer it two
    /// different ways.
    ///
    /// Counts files as well as notes, unlike the prompts above: at quit the
    /// reader cannot see the strip, so a note count alone does not tell them how
    /// much of their afternoon this is. Phrased to sit beside sentences like "the
    /// agent session is running and will be stopped" — declarative, in the
    /// future tense, one line — with the recoverability clause folded in rather
    /// than appended, because that list has no room for a second sentence per
    /// reason.
    ///
    /// Returns nil when there is nothing to say, so a host can append it
    /// unconditionally.
    public static func quitReason(count: Int, fileCount: Int) -> String? {
        guard count > 0 else { return nil }
        let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
        return "\(notesPhrase(count)) on \(files) in the Files tab will be "
            + "discarded and cannot be recovered."
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
