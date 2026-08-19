import Foundation

/// Accumulates paths in any order and encodes them into a `FileCorpus`.
///
/// Separate from the walk because the two have different jobs and different
/// failure modes: the walk decides *what* is in the index, and this decides
/// how it is laid out. Keeping them apart is also what lets the encoder be
/// tested against a handful of literal paths rather than a directory tree.
///
/// ### Why paths are buffered flat and sorted afterwards
///
/// Front-coding only pays when neighbours are similar, which requires sorted
/// input, and the walk cannot produce sorted output — it visits directories in
/// whatever order the file system lists them, and on APFS `readdir` returns
/// hash order rather than alphabetical. So paths land in a flat arena first
/// and the sort happens over indices into it.
///
/// The arena is the uncompressed size, 38 MB on a 314,108-file tree, and it is
/// freed the moment `finish()` returns the 8.3 MB corpus. That peak is the
/// price of sorting, and it is paid once per walk rather than per open.
struct FileCorpusWriter {

    /// Every path's bytes, back to back, unsorted.
    private var arena: [UInt8] = []
    /// `(start, length, modifiedDays, isDirectory)` per path, into `arena`.
    private var entries: [(start: Int32, length: Int32, days: UInt16, directory: Bool)] = []

    init(reservingCapacity paths: Int = 0) {
        if paths > 0 {
            arena.reserveCapacity(paths * 96)
            entries.reserveCapacity(paths)
        }
    }

    var count: Int { entries.count }

    /// Add one path, relative to the root the corpus will carry.
    mutating func add(
        relativePath: some Sequence<UInt8>, modified: Date?, isDirectory: Bool
    ) {
        let start = Int32(arena.count)
        arena.append(contentsOf: relativePath)
        let length = Int32(arena.count) - start
        entries.append((start, length, Self.days(from: modified), isDirectory))
    }

    mutating func add(relativePath: String, modified: Date?, isDirectory: Bool) {
        add(
            relativePath: Array(relativePath.utf8),
            modified: modified,
            isDirectory: isDirectory
        )
    }

    /// Add a path assembled from a parent's bytes and a child's name, without
    /// building either as a `String`.
    ///
    /// The walk calls this once per entry, so a `String` here is a heap
    /// allocation per file in the tree — four hundred thousand of them on this
    /// machine, which measured as most of the walk's cost. The bytes are
    /// already in hand on both sides; joining them in the arena skips the
    /// round trip through `String` entirely.
    mutating func add(
        parent: ArraySlice<UInt8>,
        name: UnsafeRawBufferPointer,
        modified: Date?,
        isDirectory: Bool
    ) {
        let start = Int32(arena.count)
        if !parent.isEmpty {
            arena.append(contentsOf: parent)
            arena.append(0x2F)  // '/'
        }
        arena.append(contentsOf: name)
        let length = Int32(arena.count) - start
        entries.append((start, length, Self.days(from: modified), isDirectory))
    }

    /// The bytes of the entry added last, for a caller that needs to queue a
    /// directory it has just recorded.
    var lastEntryBytes: ArraySlice<UInt8> {
        guard let last = entries.last else { return arena[0..<0] }
        return arena[Int(last.start)..<Int(last.start + last.length)]
    }

    /// Sort, front-code, and hand back the corpus.
    consuming func finish(root: String) -> FileCorpus {
        var order = Array(entries.indices)
        arena.withUnsafeBufferPointer { bytes in
            let base = bytes.baseAddress!
            order.sort { left, right in
                let l = entries[left], r = entries[right]
                let shared = Int(min(l.length, r.length))
                let comparison = shared == 0
                    ? 0
                    : Int(memcmp(base + Int(l.start), base + Int(r.start), shared))
                if comparison != 0 { return comparison < 0 }
                return l.length < r.length
            }
        }

        var blob: [UInt8] = []
        blob.reserveCapacity(arena.count / 4 + 1024)
        var restarts: [UInt32] = []
        var bags: [UInt64] = []
        var modifiedDays: [UInt16] = []
        var directoryBits = [UInt64](repeating: 0, count: (order.count + 63) / 64)
        bags.reserveCapacity(order.count)
        modifiedDays.reserveCapacity(order.count)
        restarts.reserveCapacity(order.count / FileCorpus.restartInterval + 1)

        var previous: [UInt8] = []
        var longest = 1

        for (position, index) in order.enumerated() {
            let entry = entries[index]
            let current = Array(
                arena[Int(entry.start)..<Int(entry.start + entry.length)]
            )
            longest = max(longest, current.count)

            // A restart entry is stored whole, because a decoder seeking here
            // has nothing to reconstruct from.
            let isRestart = position % FileCorpus.restartInterval == 0
            if isRestart { restarts.append(UInt32(blob.count)) }

            var shared = 0
            if !isRestart {
                let limit = min(previous.count, current.count, 255)
                while shared < limit, previous[shared] == current[shared] {
                    shared += 1
                }
            }
            let suffix = current.count - shared
            blob.append(UInt8(shared))
            blob.append(UInt8(suffix & 0xFF))
            blob.append(UInt8(suffix >> 8))
            blob.append(contentsOf: current[shared...])

            bags.append(FileCharBag.bag(of: current))
            modifiedDays.append(entry.days)
            if entry.directory {
                directoryBits[position >> 6] |= 1 << UInt64(position & 63)
            }
            previous = current
        }

        return FileCorpus(
            image: FileCorpusImage.build(
                blob: blob,
                restarts: restarts,
                bags: bags,
                modifiedDays: modifiedDays,
                directoryBits: directoryBits,
                maxEntryLength: longest,
                entryCount: order.count,
                root: root
            )
        )
    }

    private static func days(from date: Date?) -> UInt16 {
        guard let date else { return 0 }
        let interval = date.timeIntervalSince(FileCorpus.dayZero) / 86_400
        // Clamped rather than wrapped: a file dated in 2199 or in 1970 should
        // rank as very new or very old, not as its own opposite.
        return UInt16(max(0, min(Double(UInt16.max), interval.rounded(.down))))
    }
}
