import Foundation

/// Every indexed path under one root, stored as bytes rather than objects.
///
/// ### Why this shape
///
/// The index it replaces held two `String`s and a `URL` per file. Measured on
/// a 314,108-file tree that is 56 MB for data whose bytes are 38.1 MB, and the
/// gap is allocator overhead: a Swift `String` is a heap allocation, and an
/// array of them is a million reference counts to touch every time it is
/// copied.
///
/// Here the paths are one contiguous blob and everything else is a flat array
/// indexed in parallel. Nothing becomes a `String` until a row is drawn.
///
/// ### Sorted, and front-coded because it is sorted
///
/// Neighbours in a sorted path list share almost all their text, so each entry
/// stores only how many leading bytes it shares with its predecessor and the
/// bytes that differ. Measured: **38.1 MB of paths become 8.3 MB**, and
/// scanning the compressed form costs nothing — 57.7 ms against 57.6 ms flat.
///
/// Sorting buys the other half too. Everything beneath a directory is
/// *contiguous*, so asking for a subtree is two binary searches rather than a
/// second index — which is why nesting is free, and why indexing `~` means
/// `~/projects` is already indexed.
///
/// ### The form on disk is this form
///
/// These bytes are written and mapped back verbatim. Persisting is a write,
/// loading is an `mmap`, and two applications mapping the same file share one
/// copy in the page cache. There is deliberately no second representation and
/// no parse step to go wrong.
public struct FileCorpus: @unchecked Sendable {

    /// How many entries sit between restart points.
    ///
    /// A front-coded record can only be read forwards from a whole one, so
    /// every 64th entry is stored complete and its offset recorded. That costs
    /// 4,908 offsets — 20 KB — on this corpus, and buys the two things the
    /// picker cannot do without: binary search, which is what makes a subtree
    /// a range, and clean boundaries for parallel scanning.
    static let restartInterval = 64

    /// The bytes, and what keeps them alive.
    ///
    /// Everything below is a typed view into this one block. A walk allocates
    /// it; a load maps it; nothing copies it. See `FileCorpusImage`.
    let image: FileCorpusImage

    /// `[shared: UInt8][suffixLength: UInt16][suffix bytes]` per entry, in
    /// sorted order. Paths are relative to `root`.
    let blob: UnsafeBufferPointer<UInt8>

    /// Byte offset into `blob` of every `restartInterval`-th entry. Entries at
    /// these offsets always have `shared == 0`.
    let restarts: UnsafeBufferPointer<UInt32>

    /// `FileCharBag` per entry, in entry order.
    let bags: UnsafeBufferPointer<UInt64>

    /// Modification time per entry, in days since `dayZero`, saturating.
    ///
    /// Two bytes, not eight. Ranking asks whether a file was touched recently,
    /// never at what second, and day resolution answers that for 800 KB where
    /// a `Date` would cost 2.5 MB.
    let modifiedDays: UnsafeBufferPointer<UInt16>

    /// One bit per entry, set when the entry is a directory.
    ///
    /// Directories are indexed alongside files because they cost almost
    /// nothing: measured, all 85,033 of them added **0.3 MB** to an 8.3 MB
    /// corpus — a directory path is very nearly the shared prefix of the
    /// entries beneath it, so front-coding stores it in a few bytes. What they
    /// buy is re-rooting and path completion answered from memory rather than
    /// from the disk.
    let directoryBits: UnsafeBufferPointer<UInt64>

    /// The longest entry, so a decoder can size its buffer once.
    let maxEntryLength: Int

    public let entryCount: Int

    /// The root every entry is relative to, canonical.
    public let root: String

    /// Build a corpus from an image, which is the only way one is made.
    init(image: FileCorpusImage) {
        self.image = image
        let header = image.header
        entryCount = Int(header.entryCount)
        maxEntryLength = max(1, Int(header.maxEntryLength))
        blob = UnsafeBufferPointer(
            start: (image.base + Int(header.blobOffset))
                .assumingMemoryBound(to: UInt8.self),
            count: Int(header.blobByteCount)
        )
        restarts = UnsafeBufferPointer(
            start: (image.base + Int(header.restartsOffset))
                .assumingMemoryBound(to: UInt32.self),
            count: Int(header.restartCount)
        )
        bags = UnsafeBufferPointer(
            start: (image.base + Int(header.bagsOffset))
                .assumingMemoryBound(to: UInt64.self),
            count: entryCount
        )
        modifiedDays = UnsafeBufferPointer(
            start: (image.base + Int(header.modifiedOffset))
                .assumingMemoryBound(to: UInt16.self),
            count: entryCount
        )
        directoryBits = UnsafeBufferPointer(
            start: (image.base + Int(header.directoryBitsOffset))
                .assumingMemoryBound(to: UInt64.self),
            count: (entryCount + 63) / 64
        )
        root = String(
            decoding: UnsafeRawBufferPointer(
                start: image.base + Int(header.rootOffset),
                count: Int(header.rootByteCount)
            ),
            as: UTF8.self
        )
    }

    /// Load a corpus previously written to disk, or nil if it is absent or
    /// unreadable. An unreadable corpus is always rebuildable, so a caller's
    /// correct response to nil is to walk again rather than to fail.
    public static func load(from url: URL) -> FileCorpus? {
        guard let image = FileCorpusImage.map(url) else { return nil }
        return FileCorpus(image: image)
    }

    /// Days are counted from 2020-01-01, which keeps a `UInt16` good until
    /// 2199 and puts every plausible file comfortably inside it.
    static let dayZero = Date(timeIntervalSince1970: 1_577_836_800)

    /// Today, in the same units the corpus stores, for scoring recency.
    ///
    /// Read once per query rather than per candidate — it is a clock call, and
    /// a clock call in the inner loop would cost more than the bonus it
    /// computes.
    static var today: UInt16 {
        let days = Date().timeIntervalSince(dayZero) / 86_400
        return UInt16(max(0, min(Double(UInt16.max), days.rounded(.down))))
    }

    public var isEmpty: Bool { entryCount == 0 }

    // MARK: - Reading

    /// Run `body` over each entry in `range`, in order.
    ///
    /// The bytes handed over are the decoder's own buffer and are valid only
    /// for the duration of the call — copying them per entry is exactly the
    /// per-candidate allocation this type exists to avoid.
    ///
    /// Returning `false` stops the walk, which is how the matcher answers
    /// cancellation without waiting for the end of a block.
    func forEachEntry(
        in range: Range<Int>,
        _ body: (_ index: Int, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= entryCount
        else { return }

        var buffer = [UInt8](repeating: 0, count: maxEntryLength)
        let block = range.lowerBound / Self.restartInterval
        var offset = Int(restarts[block])
        var length = 0
        var index = block * Self.restartInterval

        let source = blob
        buffer.withUnsafeMutableBufferPointer { scratch in
                while index < range.upperBound {
                    let shared = Int(source[offset])
                    let suffix =
                        Int(source[offset + 1]) | (Int(source[offset + 2]) << 8)
                    offset += 3
                    if suffix > 0 {
                        scratch.baseAddress!.advanced(by: shared)
                            .update(from: source.baseAddress! + offset, count: suffix)
                    }
                    length = shared + suffix
                    offset += suffix

                    if index >= range.lowerBound {
                        let view = UnsafeBufferPointer(
                            start: scratch.baseAddress, count: length
                        )
                        if !body(index, view) { return }
                    }
                index += 1
            }
        }
    }

    /// The path at `index`, relative to `root`.
    public func relativePath(at index: Int) -> String {
        var result = ""
        forEachEntry(in: index..<(index + 1)) { _, bytes in
            result = String(decoding: bytes, as: UTF8.self)
            return false
        }
        return result
    }

    /// The absolute path at `index`.
    public func path(at index: Int) -> String {
        root + "/" + relativePath(at: index)
    }

    public func isDirectory(at index: Int) -> Bool {
        directoryBits[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    public func modified(at index: Int) -> Date {
        Self.dayZero.addingTimeInterval(Double(modifiedDays[index]) * 86_400)
    }

    // MARK: - Subtree ranges

    /// The entries beneath `subroot`, which is absolute.
    ///
    /// Returns an empty range when `subroot` is outside this corpus, and the
    /// whole corpus when it *is* the root.
    public func range(under subroot: String) -> Range<Int> {
        let canonical = FilePaths.canonical(URL(fileURLWithPath: subroot))
        if canonical == root { return 0..<entryCount }
        guard let relative = FilePaths.relative(canonical, under: root) else {
            return 0..<0
        }
        // Everything under `foo/bar` sorts between `foo/bar/` and `foo/bar0`,
        // because `0` is the byte after `/`. Comparing against the separator
        // rather than the bare name is what keeps `project-other` out of
        // `project`.
        let lower = Array((relative + "/").utf8)
        var upper = lower
        upper[upper.count - 1] = 0x30  // '/' + 1
        return firstIndex(atOrAfter: lower)..<firstIndex(atOrAfter: upper)
    }

    /// The first entry that is not ordered before `needle`.
    func firstIndex(atOrAfter needle: [UInt8]) -> Int {
        var low = 0
        var high = entryCount
        while low < high {
            let mid = (low + high) / 2
            if compare(entryAt: mid, with: needle) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func compare(entryAt index: Int, with needle: [UInt8]) -> Int {
        var result = 0
        forEachEntry(in: index..<(index + 1)) { _, bytes in
            let shared = min(bytes.count, needle.count)
            for offset in 0..<shared where bytes[offset] != needle[offset] {
                result = bytes[offset] < needle[offset] ? -1 : 1
                return false
            }
            if result == 0, bytes.count != needle.count {
                result = bytes.count < needle.count ? -1 : 1
            }
            return false
        }
        return result
    }
}
