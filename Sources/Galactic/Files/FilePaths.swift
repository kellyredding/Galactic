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
    /// Compared component-wise rather than by string prefix, so a sibling
    /// directory whose name merely begins with the root's — `project-other`
    /// against `project` — is correctly outside it.
    public static func relativePath(of url: URL, under root: URL) -> String? {
        let child = canonical(url).split(separator: "/").map(String.init)
        let base = canonical(root).split(separator: "/").map(String.init)
        guard child.count > base.count, Array(child.prefix(base.count)) == base
        else { return nil }
        return child.dropFirst(base.count).joined(separator: "/")
    }
}
