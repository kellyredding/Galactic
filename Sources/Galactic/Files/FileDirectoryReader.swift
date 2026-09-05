import Foundation

/// Reads a directory for the file panels.
///
/// **One reader, so a directory cannot be listed two ways.** It began on the
/// picker's presenter because that was the only caller; the root field is a
/// third, and a third caller reaching into the picker for it is exactly how
/// "one reader" stops being true.
///
/// Every rule below is a measured trap rather than a preference, which is why
/// this is not three lines.
///
/// **Answered from disk rather than from the index, deliberately.** The index
/// skips names a browser must still show: `node_modules`, `.git`, `build`, and
/// `Library` under a home directory. A corpus-answered expansion could not
/// reach any of them, and a file browser that omits directories visibly on disk
/// is lying rather than filtering.
enum FileDirectoryReader {

    /// The child directories of a path.
    ///
    /// `nonisolated static` so a detached read cannot reach presenter state,
    /// which is what keeps this off the main actor by construction rather than
    /// by remembering to.
    ///
    /// Hidden entries are included — `options: []` does not pass
    /// `.skipsHiddenFiles` — and that is wanted: `~/.claude` is somewhere a
    /// reader goes.
    ///
    /// **Each child is spelled against the parent it was asked for, not taken
    /// from the enumerated URL.** Measured: asked for
    /// `/var/folders/…/T/x`, `contentsOfDirectory` answers
    /// `/private/var/folders/…/T/x/alpha`, because `/var` is a symlink. Every
    /// caller here matches these against what the reader typed, so a resolved
    /// spelling fails `hasPrefix` against an unresolved one and the folder list
    /// silently comes back empty. `/tmp`, `/var` and `/etc` are all symlinks on
    /// macOS, which is why `/tmp/` has never tab-completed.
    ///
    /// Resolving the reader's text instead would be the other repair and is
    /// worse: it rewrites the field under them, and `~` is deliberately kept
    /// unexpanded there for exactly that reason.
    nonisolated static func childDirectories(of path: String) -> [String] {
        childEntries(of: path)
            .filter { $0.isDirectory }
            .map { $0.path }
    }

    /// Everything in a directory, files included, each flagged.
    ///
    /// What the tree expands with. Both notes above apply to it unchanged.
    /// **A symlinked directory is read by path, because the URL form refuses
    /// it.** Measured: for a link pointing at a directory,
    /// `contentsOfDirectory(at:)` throws while `contentsOfDirectory(atPath:)`
    /// on the same string answers its contents. Without the second attempt a
    /// symlinked folder expands to nothing — it opens, it is a directory, and
    /// it is empty, which reads as a genuinely empty folder rather than as a
    /// failure. `~/projects/implementation-plans` is one such link.
    ///
    /// Tried in this order rather than always by path: the URL form prefetches
    /// the resource values `isBrowsableDirectory` then reads back for free,
    /// and paying a fresh `stat` per entry on every ordinary directory is the
    /// cost this file already has performance history about.
    nonisolated static func childEntries(
        of path: String
    ) -> [FileTreeOutline.Entry] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ],
            options: []
        ) {
            return contents.map { url in
                FileTreeOutline.Entry(
                    path: prefix + url.lastPathComponent,
                    isDirectory: isBrowsableDirectory(url)
                )
            }
        }
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                atPath: path
            )
        else { return [] }
        return names.map { name in
            FileTreeOutline.Entry(
                path: prefix + name,
                isDirectory: isBrowsableDirectory(
                    URL(fileURLWithPath: prefix + name)
                )
            )
        }
    }

    /// Whether a directory entry is somewhere a panel can browse into.
    ///
    /// **`isDirectoryKey` has `lstat` semantics: it is false for every symlink,
    /// including one pointing straight at a directory.** Measured — `/tmp`,
    /// `/var`, `/etc` and `~/projects/implementation-plans` all answer false,
    /// so enumerating `/` with that predicate alone yields no `tmp`, `var` or
    /// `etc` at all, and a symlinked project folder is invisible.
    ///
    /// `resolvingSymlinksInPath()` is not the repair: measured, it answers
    /// false for `/tmp` and true for `implementation-plans`, so it disagrees
    /// with itself. `fileExists(atPath:isDirectory:)` follows the link and was
    /// true for every case above, so the link is settled with a `stat` — but
    /// only when the entry *is* a link, which keeps one syscall off the
    /// overwhelming majority of entries that are ordinary directories.
    private nonisolated static func isBrowsableDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        if values?.isDirectory == true { return true }
        guard values?.isSymbolicLink == true else { return false }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}
