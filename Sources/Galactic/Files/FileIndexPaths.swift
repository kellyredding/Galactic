import Foundation

/// Where the shared file index lives, and the guarantees that come with the
/// directory it lives in.
///
/// `~/.galactic/` is deliberately outside any application's own container: one
/// index serves every Galactic application, and an index inside Assist Ant's
/// support directory would be Assist Ant's index that Galaxy happened to read.
public enum FileIndexPaths {

    /// Overridable so tests never touch the real one.
    ///
    /// An environment variable rather than an injected parameter because the
    /// things that need redirecting — a walker on a background queue, a
    /// watcher, a logger — are reached from too many places to thread a value
    /// through, and every one of them would otherwise have to be trusted to
    /// pass the test's copy rather than the default.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["GALACTIC_HOME"] {
            return URL(fileURLWithPath: override)
        }
        // A test process must never write to the real index, and relying on
        // every test to remember to redirect it does not hold: the presenter's
        // own tests index temporary directories as a side effect of exercising
        // the picker, and they put 3.9 MB of shards for dead temp roots into a
        // real home directory before this guard existed. The failure is silent
        // and the residue outlives the run, which is the combination worth
        // spending a branch on.
        if NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("galactic-tests-\(getpid())")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".galactic")
    }

    public static var indexDirectory: URL {
        root.appendingPathComponent("index")
    }

    public static var logsDirectory: URL {
        root.appendingPathComponent("logs")
    }

    public static var catalogFile: URL {
        indexDirectory.appendingPathComponent("catalog.db")
    }

    /// The file the single-writer lease is taken on.
    ///
    /// **Never replaced, and that is load-bearing.** An advisory lock hangs off
    /// the vnode rather than the path, so renaming a new file over a locked one
    /// leaves the holder attached to an orphaned inode while the next process
    /// takes an uncontended lock on the new one — two writers, both believing
    /// they are alone. The corpus files are replaced constantly; this one never
    /// is.
    public static var lockFile: URL {
        indexDirectory.appendingPathComponent("lock")
    }

    /// The log's own lease, separate from the writer lease above.
    ///
    /// Sharing one file made a log rotation able to turn a publish into a
    /// no-op, since the lease does not wait and a losing publish never comes
    /// back. Rotation and shard-building protect different things and contend
    /// for nothing, so they get a file each.
    ///
    /// Never replaced, for the reason the writer lease is never replaced.
    public static var logLockFile: URL {
        logsDirectory.appendingPathComponent("lock")
    }

    /// Where one root's shards live. Named by a hash so a path with slashes,
    /// spaces or accents cannot become a directory name.
    public static func shardDirectory(forCanonicalRoot root: String) -> URL {
        indexDirectory.appendingPathComponent(rootIdentifier(root))
    }

    /// A stable, filesystem-safe name for a root path.
    ///
    /// FNV-1a rather than a cryptographic hash: this is a filename, not a
    /// security boundary, and the catalog stores the real path alongside so a
    /// collision would be visible rather than silent.
    public static func rootIdentifier(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    // MARK: - Creation and hygiene

    /// Create the directories, then assert the privacy properties.
    ///
    /// Asserted **on every launch** rather than once at creation. The index is
    /// a plaintext list of every filename its owner has, so the cost of one of
    /// these silently coming undone — a directory restored from a backup,
    /// copied by hand, or created by an older build — is a list of someone's
    /// entire disk ending up somewhere it was never meant to go. Re-asserting
    /// is a handful of syscalls at launch, and it makes the guarantee
    /// self-healing rather than historical.
    @discardableResult
    public static func prepare() -> Bool {
        let manager = FileManager.default
        do {
            for directory in [root, indexDirectory, logsDirectory] {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try manager.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path
                )
            }

            // Time Machine. The sanctioned API, and it needs no privileges.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = root
            try marked.setResourceValues(values)

            // Spotlight. Without this the index becomes searchable content in
            // its own right — every filename on the disk, indexed twice.
            let neverIndex = root.appendingPathComponent(".metadata_never_index")
            if !manager.fileExists(atPath: neverIndex.path) {
                manager.createFile(atPath: neverIndex.path, contents: Data())
            }
            return true
        } catch {
            return false
        }
    }

    /// Whether the privacy properties currently hold. For the smoke check, and
    /// for anyone debugging a directory that has been moved around by hand.
    public static func privacyHolds() -> (
        excludedFromBackup: Bool, spotlightMarker: Bool, permissions: Bool
    ) {
        let manager = FileManager.default
        let excluded =
            (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup ?? false
        let marker = manager.fileExists(
            atPath: root.appendingPathComponent(".metadata_never_index").path
        )
        let mode =
            (try? manager.attributesOfItem(atPath: root.path))?[
                .posixPermissions
            ] as? NSNumber
        return (excluded, marker, mode?.int16Value == 0o700)
    }
}
