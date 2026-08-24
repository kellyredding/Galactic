import Foundation

/// The state of a panel's root field: what is typed, and which of the folders it
/// could mean is picked.
///
/// A value rather than a presenter, and the candidate folders arrive as
/// arguments — the same division `FileFolderList` and
/// `FileRootInput.completion(for:directories:)` already draw, and what keeps
/// every rule here testable without a filesystem.
///
/// ### The field is a path, so it does not ask whether it is one
///
/// `FileRootInput.isRootChange` exists because the picker's *search* field does
/// two jobs and has to tell them apart. This field has one job, so the
/// predicate would only ever refuse text a reader plainly meant as a path:
/// clearing the field and typing `src` is a path relative to the root, not a
/// filter. Relative text is resolved here rather than by widening
/// `isRootChange`, whose present meaning other callers still read.
public struct FileRootField: Equatable {

    /// What is typed, exactly as typed.
    ///
    /// **Never rewritten except by `complete` and `reset`.** `~` stays
    /// unexpanded and a leading `.` or `..` stays as written, because the
    /// alternative is the field editing itself under the reader — the same
    /// reason `FileRootInput.completion` re-abbreviates on the way out.
    public var text: String

    /// Which offered folder is picked, or nil for "whatever is typed".
    ///
    /// Nil rather than zero, and that is the distinction the picker's
    /// `selectionIsExplicit` draws for the same reason: "the folder I chose" and
    /// "the folder I named" resolve differently, and only an arrow key makes it
    /// the former.
    public private(set) var selection: Int?

    public init(text: String = "") {
        self.text = text
        self.selection = nil
    }

    // MARK: - Filling and clearing

    /// Fill from a root, abbreviated for reading.
    ///
    /// A reader recognises `~/projects/app` faster than they recognise
    /// `/Users/them/projects/app`, and the completion rules already speak `~`,
    /// so the abbreviated form is what the field should open holding.
    public mutating func reset(to root: URL?) {
        selection = nil
        guard let root else {
            text = ""
            return
        }
        let path = root.path
        let home = NSHomeDirectory()
        if path == home {
            text = "~"
        } else if path.hasPrefix(home + "/") {
            text = "~" + path.dropFirst(home.count)
        } else {
            text = path
        }
    }

    public mutating func clearSelection() {
        selection = nil
    }

    /// Move the pick, clamped, and with no wrap.
    ///
    /// Clamped rather than wrapped so holding an arrow settles at an end
    /// instead of cycling — a list you are reading should stop where it stops.
    public mutating func moveSelection(by delta: Int, rowCount: Int) {
        guard rowCount > 0 else {
            selection = nil
            return
        }
        let current = selection ?? -1
        selection = min(rowCount - 1, max(0, current + delta))
    }

    // MARK: - Asking about the path

    /// What the field means, expanded, with `~` resolved and any leading `.` or
    /// `..` settled against `route`.
    ///
    /// Nil only for empty text.
    public func expandedPath(route: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = FileRootInput.expandedPath(trimmed, route: route) {
            return absolute
        }
        // Not a path by the picker's predicate, which here means it is relative
        // to where we already are.
        guard let route else { return nil }
        let base = route.hasSuffix("/") ? String(route.dropLast()) : route
        return base + "/" + trimmed
    }

    /// The directory whose children the field is choosing between.
    public func candidateParent(route: String?) -> String? {
        guard let typed = expandedPath(route: route) else { return nil }
        guard typed.hasSuffix("/") else {
            return (typed as NSString).deletingLastPathComponent
        }
        return typed == "/" ? "/" : String(typed.dropLast())
    }

    /// The folders to offer for what is typed.
    public func rows(
        children: [String],
        route: String?,
        limit: Int = FileFolderList.rowLimit
    ) -> [FilePickerItem] {
        guard let typed = expandedPath(route: route) else { return [] }
        return FileFolderList.rows(
            for: typed, children: children, route: route, limit: limit
        )
    }

    /// Tab. The extended text, or nil when there is nothing to add.
    public func completion(
        directories: [String], route: String?
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Handed the text as typed, so `~` survives into the answer.
        if FileRootInput.isRootChange(trimmed, route: route) {
            return FileRootInput.completion(
                for: trimmed, directories: directories, route: route
            )
        }
        // Relative text has no spelling of its own to preserve, so it is
        // completed as the absolute path it names.
        guard let expanded = expandedPath(route: route) else { return nil }
        return FileRootInput.completion(
            for: expanded, directories: directories, route: route
        )
    }

    /// Return. Where this commits to, or nil when it names nothing.
    ///
    /// An explicit pick wins over the text; otherwise the text is taken. **A
    /// path that is not a directory on disk resolves to nil rather than to a
    /// URL**, so a caller refuses instead of re-rooting somewhere that is not
    /// there — the guard the picker's own re-root already applies.
    public func resolved(
        rows: [FilePickerItem], route: String?
    ) -> URL? {
        if let selection, rows.indices.contains(selection) {
            return rows[selection].url
        }
        guard let typed = expandedPath(route: route) else { return nil }
        let path =
            typed.count > 1 && typed.hasSuffix("/")
            ? String(typed.dropLast()) : typed
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: path, isDirectory: &isDirectory
            ), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
