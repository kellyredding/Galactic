import Foundation

/// What the picker says when it has no rows to show.
///
/// Five different nothings, and a reader acts on each differently — so the
/// message is a decision rather than a fallback, and the *order* the cases are
/// tried in is part of that decision. Extracted from the view and pinned by
/// tests for the same reason `FileConfirmations` is: wording is what drifts, and
/// a five-branch precedence is exactly the shape that goes wrong silently. A
/// wrong empty state does not fail; it just tells a reader something untrue
/// about why they are looking at nothing.
enum FilePickerEmptyState {

    /// - Parameters:
    ///   - hasRoot: whether there is a tree to search at all.
    ///   - isIndexing: whether the walk is still running.
    ///   - isRootChange: whether what has been typed is a path rather than a
    ///     query — the picker's other mode.
    ///   - query: what has been typed.
    static func message(
        hasRoot: Bool,
        isIndexing: Bool,
        isRootChange: Bool,
        query: String
    ) -> String {
        // No tree beats every other answer: nothing below it can be true, and a
        // reader told to type would be typing into a search of nowhere.
        guard hasRoot else { return "No folder to browse" }

        // Before the root-change hint, because a walk in progress is the reason
        // there are no rows yet and saying so is more useful than instructions
        // for something they can do a moment later anyway.
        if isIndexing { return "Reading the folder…" }

        // The other mode, and it needs its instructions while the path is
        // half-typed rather than after.
        if isRootChange { return "Return to browse here, Tab to complete" }

        if query.isEmpty { return emptyQuery }

        return "No file matches"
    }

    /// The first thing anyone sees, and the one worth writing carefully.
    ///
    /// It replaced "Nothing open or closed yet — type to search", which described
    /// the two lists that feed this space — closed tabs, then recent files — to a
    /// reader who has no reason to know either exists. Worse, it read as *there
    /// are no files*, when a tree of them had just been indexed and was one
    /// keystroke away.
    ///
    /// So: the action first, because that is what the reader needs, and then what
    /// the space is for, because that is what stops them wondering next time.
    ///
    /// **"previously opened", not "you open".** The two lists behind this space
    /// are closed tabs and `presentedRecents`, and that second one subtracts
    /// whatever currently has a tab — deliberately, since a file already on
    /// screen is not a suggestion. So a file open right now appears in neither,
    /// and the earlier wording promised a reader with two files open that they
    /// would be listed here. They only arrive once closed.
    static let emptyQuery =
        "Type to search. Files you've previously opened will be listed here."
}
