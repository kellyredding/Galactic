import Foundation

/// Writing a corpus to disk, and replacing one that readers may be holding.
public enum FileCorpusFile {

    public enum WriteError: Error {
        case couldNotCreate(String)
        case couldNotWrite(String)
        case couldNotPublish(String)
    }

    /// Write a corpus and put it in place, atomically.
    ///
    /// The sequence is not decoration, and each step answers a specific way
    /// this goes wrong:
    ///
    /// 1. **Write a temporary file.** Never the live one. A reader holding a
    ///    mapping of a file that is then truncated takes a `SIGBUS` — verified
    ///    on this machine, not inferred.
    /// 2. **`F_FULLFSYNC`.** `fsync` returns once the data reaches the drive's
    ///    cache, and Apple's own man page calls the resulting corruption
    ///    window "not a theoretical edge case". This is the call that flushes
    ///    the drive.
    /// 3. **`rename`.** Atomic by contract, and — the property this design
    ///    rests on — a mapping holds a reference to the *inode*, not the path.
    ///    A reader mid-search keeps reading consistent old bytes; new readers
    ///    open the new file; the old inode's storage is reclaimed when the
    ///    last mapping drops.
    /// 4. **`fsync` the directory.** Otherwise the rename itself may not
    ///    survive a power failure, and the file is written but unnamed.
    @discardableResult
    public static func write(_ corpus: FileCorpus, to url: URL) throws -> Int {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        // Unique per process and per attempt. A fixed name meant two writers
        // publishing the same shard at the same generation opened the same file
        // with O_TRUNC and interleaved into it — and since the image header
        // carries no checksum, two writes of equal length would then validate
        // clean and yield garbage paths. The writer lease prevents that today,
        // which is exactly the problem: the whole guarantee rested on one lock
        // being correct with nothing behind it.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
            )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw WriteError.couldNotCreate(temporary.path)
        }

        var written = 0
        try corpus.image.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress! + offset, bytes.count - offset
                )
                if count <= 0 {
                    close(descriptor)
                    try? FileManager.default.removeItem(at: temporary)
                    throw WriteError.couldNotWrite(temporary.path)
                }
                offset += count
            }
            written = offset
        }

        // Ask the drive, not just the file system.
        if fcntl(descriptor, F_FULLFSYNC) == -1 { fsync(descriptor) }
        close(descriptor)

        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteError.couldNotPublish(url.path)
        }

        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
        return written
    }

    /// The file a shard's corpus lives in, at a given generation.
    ///
    /// The generation is in the **filename**, not only in the catalog, so a
    /// reader opens a specific version by name and never has to detect that a
    /// path it already opened has been replaced underneath it. Inode-based
    /// detection was the alternative and it is unsound here: Foundation's
    /// `replaceItemAt` explicitly declines to promise inode preservation.
    public static func url(
        shardDirectory: URL, shard: String, generation: UInt64
    ) -> URL {
        shardDirectory.appendingPathComponent("\(shard)-\(generation).gfsi")
    }

    /// Delete every generation of a shard except the one named.
    ///
    /// Called after a new generation is published and readers have been told.
    /// Both generations occupy disk *and* page cache until the old one is
    /// unlinked and its last mapping drops, so leaving them accumulating would
    /// cost a multiple of the index in both.
    public static func removeSupersededGenerations(
        shardDirectory: URL, shard: String, keeping generation: UInt64
    ) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                atPath: shardDirectory.path
            )
        else { return }
        let keep = "\(shard)-\(generation).gfsi"
        for entry in entries
        where entry.hasPrefix("\(shard)-")
            && (entry.hasSuffix(".gfsi") || entry.hasSuffix(".tmp"))
            && entry != keep
        {
            // Temporary files are reaped here rather than only when a shard is
            // pruned. A process that died between writing and renaming leaves
            // one behind, and nothing else would ever look: this runs under the
            // writer lease, so no other process can be mid-write on this shard.
            try? manager.removeItem(
                at: shardDirectory.appendingPathComponent(entry)
            )
        }
    }

    /// Delete every generation of a shard, and any temporary file left behind.
    ///
    /// For a shard that should no longer exist rather than one being replaced.
    /// The `.tmp` sweep is here because nothing else does it: a process that
    /// died between writing and renaming leaves a file that
    /// `removeSupersededGenerations` filters out by suffix and never reclaims.
    public static func removeAllGenerations(
        shardDirectory: URL, shard: String
    ) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                atPath: shardDirectory.path
            )
        else { return }
        for entry in entries
        where entry.hasPrefix("\(shard)-")
            && (entry.hasSuffix(".gfsi") || entry.hasSuffix(".tmp"))
        {
            try? manager.removeItem(
                at: shardDirectory.appendingPathComponent(entry)
            )
        }
    }
}
