import Foundation

/// Deciding whether one path is inside another.
///
/// Its own type because getting this wrong is silent. Three places need the
/// answer — the index, a tab's label, and a review's citation — and if they
/// disagree the reader sees a picker full of absolute paths where relative ones
/// were meant, with nothing failing.
public enum FilePaths {

    /// The canonical path, with every symlink resolved.
    ///
    /// Through `realpath` rather than either Foundation spelling, because
    /// neither is reliable here and the two are not even consistent with each
    /// other:
    ///
    /// - `resolvingSymlinksInPath()` leaves `/var/folders/…` alone.
    /// - `standardizedFileURL` leaves `/private/var/…` alone.
    /// - `FileManager.enumerator` hands back `/private/var/…` whichever form it
    ///   was given.
    ///
    /// So a root and its own children arrived spelled differently, the prefix
    /// test failed, and every path in the index came back absolute. `realpath`
    /// answers one way for both.
    ///
    /// Requires the path to exist; a path that does not resolve is returned as
    /// it was, which is the right answer for a file that has since been deleted.
    public static func canonical(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { representation -> String in
            guard
                let representation,
                let resolved = realpath(representation, nil)
            else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// The path of `url` relative to `root`, or nil when it is not inside it.
    ///
    /// Asked twice, because neither answer is sufficient alone:
    ///
    /// - **Canonically**, which is what handles a root reached through a
    ///   symlink. `realpath` needs the path to exist, so this is the answer for
    ///   a file that is there.
    /// - **Lexically**, for a path that cannot be resolved because it is gone.
    ///   The picker's empty list is made of files a reader *closed*, and some of
    ///   those will have been deleted since — with only the canonical test, one
    ///   unresolvable child fell back to its raw path while the root resolved,
    ///   and the row displayed a full absolute path.
    ///
    /// Compared component-wise rather than by string prefix either way, so a
    /// sibling directory whose name merely begins with the root's —
    /// `project-other` against `project` — is correctly outside it.
    public static func relativePath(of url: URL, under root: URL) -> String? {
        if let resolved = relative(canonical(url), under: canonical(root)) {
            return resolved
        }
        return relative(url.path, under: root.path)
    }

    /// The lexical answer alone, for a caller that has already canonicalised
    /// both sides and does not want the work repeated.
    ///
    /// Internal rather than private because `FileCorpus` asks it per subtree
    /// query against a root it resolved once at build time — going back
    /// through `relativePath(of:under:)` would `realpath` both sides again on
    /// every keystroke that re-roots.
    /// The relative path of an entry the file system just mentioned, against
    /// an already-canonical root.
    ///
    /// Three attempts, because the caller cannot know which applies. A path
    /// from FSEvents is already resolved and matches on the first. A path from
    /// somewhere else may still contain a symlinked prefix — `/var` against
    /// `/private/var` is the everyday case — and needs resolving. And a path
    /// that has just been **deleted** cannot be resolved at all, since
    /// `realpath` requires the file to exist; its parent still does, which is
    /// enough.
    static func relativeEntry(of path: String, underCanonical root: String)
        -> String?
    {
        if let direct = relative(path, under: root) { return direct }
        let url = URL(fileURLWithPath: path)
        if let resolved = relative(canonical(url), under: root) { return resolved }
        let parent = canonical(url.deletingLastPathComponent())
        return relative(parent + "/" + url.lastPathComponent, under: root)
    }

    static func relative(_ path: String, under base: String) -> String? {
        let child = path.split(separator: "/").map(String.init)
        let root = base.split(separator: "/").map(String.init)
        guard child.count > root.count, Array(child.prefix(root.count)) == root
        else { return nil }
        return child.dropFirst(root.count).joined(separator: "/")
    }

    /// Every absolute path from `root` down to `relative`, inclusive of both.
    ///
    /// What the picker expands to reveal a file: all of it but the last entry
    /// is the folders to open, and the last entry is the row to land on.
    ///
    /// Takes a **relative path** rather than two absolutes, because the caller
    /// has already had to decide which spelling of the file it is working in —
    /// see `FileDirectoryReader`, whose children are spelled against the parent
    /// they were asked for rather than resolved. Recomputing it here from a
    /// canonical path would answer with rows the tree does not contain.
    public static func chain(to relative: String, under root: String) -> [String]
    {
        var built = root
        var result = [root]
        for segment in relative.split(separator: "/") {
            built += "/" + segment
            result.append(built)
        }
        return result
    }
}
