import Foundation

/// Runs a literal text search over every file under a root.
///
/// ### Where the files come from
///
/// The **index**, not a fresh walk and not `.gitignore`. The picker's file list
/// comes from the index, so a searcher answering from anywhere else would find
/// files the picker cannot show and miss files it can — one root giving two
/// answers, which is the contradiction the skip list was moved into the index
/// to avoid. Enumeration is close to free as a result: a subtree of an indexed
/// root costs nothing to range, and a full pass over a 314,108-entry corpus
/// measures 57.7 ms.
///
/// The consequence is that whatever the index does not hold is not searched —
/// `log`, `tmp`, `dist`, `build`, `coverage`, `node_modules` and the rest of
/// the skip list, iCloud-evicted files, anything past the depth cap. The run
/// carries `skippedNames` so a header can say so rather than leaving a reader
/// to infer that their `log/` directory has no matches.
///
/// ### The shape of the work
///
/// Snapshot on the main actor, scan off it. That split, the swapped
/// cancellation flag, and the bounded worker count are copied from the picker's
/// matcher rather than reinvented: four measured main-actor stalls in this
/// subsystem were fixed into that shape.
@MainActor
public final class FileSearchEngine {

    public static let shared = FileSearchEngine()

    /// Internal so tests can drive an instance without disturbing the
    /// singleton every other test shares. Hosts use `shared`.
    init() {}

    /// What bounds a run.
    ///
    /// Three caps rather than one. A single total would let one pathological
    /// file — a minified bundle, a lockfile, a vendored blob — spend the whole
    /// budget and push every other file out of the results, which looks like
    /// "no other matches" rather than like a cap.
    public struct Limits: Equatable, Sendable {
        public var totalMatches: Int
        public var matchesPerFile: Int
        public var bytesPerFile: Int

        public init(
            totalMatches: Int = 2_000,
            matchesPerFile: Int = 50,
            bytesPerFile: Int = 2_000_000
        ) {
            self.totalMatches = totalMatches
            self.matchesPerFile = matchesPerFile
            self.bytesPerFile = bytesPerFile
        }

        public static let `default` = Limits()
    }

    /// Whether a run is in flight. Read by a presenter, which owns the
    /// published copy — the engine has no view and nothing observes it.
    public private(set) var isSearching = false

    private var task: Task<Void, Never>?
    private var cancellation = FileMatcher.Cancellation()

    /// Run a search, cancelling whatever was already running.
    public func search(
        query: FileSearchQuery,
        root: URL,
        limits: Limits = .default,
        onFinished: @escaping (FileSearchRun) -> Void
    ) {
        let canonical = FilePaths.canonical(root)
        // Both cheap, both main-actor, and both snapshots: a published
        // generation is immutable, so the scan cannot see the store change
        // under it. Read from the snapshot rather than the store precisely to
        // keep that true — awaiting the store here would put a suspension
        // point between choosing the root and reading it.
        let slices = FileIndexSnapshot.shared.slices(forCanonicalRoot: canonical)
        let skipped = FileIndexSnapshot.shared
            .skipList(forCanonicalRoot: canonical)

        // Swapped rather than set. Cancelling the task alone stops the *await*
        // and not the loop, which is how one walk once became sixty-three
        // overlapping passes; poisoning the old flag and installing a fresh one
        // means a late run cannot land on a newer query either.
        cancellation.cancel()
        let cancellation = FileMatcher.Cancellation()
        self.cancellation = cancellation

        task?.cancel()
        isSearching = true
        task = Task { [weak self] in
            let run = await Task.detached(priority: .userInitiated) {
                Self.run(
                    query: query,
                    slices: slices,
                    root: canonical,
                    skipped: skipped,
                    limits: limits,
                    cancellation: cancellation
                )
            }.value

            guard !Task.isCancelled, !cancellation.isCancelled else { return }
            self?.isSearching = false
            onFinished(run)
        }
    }

    public func cancel() {
        cancellation.cancel()
        task?.cancel()
        task = nil
        isSearching = false
    }

    // MARK: - Off the main actor

    nonisolated static func run(
        query: FileSearchQuery,
        slices: [FileMatcher.Slice],
        root: String,
        skipped: Set<String>,
        limits: Limits,
        cancellation: FileMatcher.Cancellation
    ) -> FileSearchRun {
        let needle = Array(query.text.utf8)
        func nothing(indexed: Bool = true) -> FileSearchRun {
            FileSearchRun(
                query: query, root: root, files: [], filesConsidered: 0,
                filesScanned: 0, matchCount: 0, truncation: nil,
                skippedNames: skipped.sorted(), wasRootIndexed: indexed
            )
        }
        guard !needle.isEmpty else { return nothing() }
        // Not the same answer as "nothing matched", and saying so is the whole
        // reason this is a separate flag: a root the index has never walked
        // returns no files for a reason that has nothing to do with the query.
        guard !slices.isEmpty else { return nothing(indexed: false) }

        let paths = collectPaths(slices: slices, cancellation: cancellation)
        guard !cancellation.isCancelled else { return nothing() }

        // Batched, in path order, stopping as soon as the cap is reached.
        //
        // Scanning everything and capping afterwards read all 54,200 files of a
        // project to report the first 2,000 matches of 2,003 — the cap bounded
        // the *output* and not the work. Batching bounds both.
        //
        // Order is what makes early termination honest: a batch is a
        // contiguous run of the sorted paths, so a truncated result is always a
        // prefix of file order and never a race between workers. Letting
        // workers stop on a shared counter would have been faster still and
        // would have made the result depend on which thread got there first.
        let batchSize = max(512, 256 * ProcessInfo.processInfo.activeProcessorCount)
        var files: [FileSearchFileResult] = []
        var matchCount = 0
        var scanned = 0
        var hitFileCap = false
        var truncation: FileSearchRun.Truncation?
        var offset = 0

        while offset < paths.count {
            if cancellation.isCancelled { return nothing() }
            let end = min(offset + batchSize, paths.count)
            let outcomes = scan(
                paths: Array(paths[offset..<end]), root: root, query: query,
                needle: needle, limits: limits, cancellation: cancellation
            )
            scanned += outcomes.scanned

            for result in outcomes.results {
                if matchCount >= limits.totalMatches {
                    truncation = .matchCap(limits.totalMatches)
                    break
                }
                files.append(result)
                matchCount += result.matchCount
                if result.wasTruncated { hitFileCap = true }
            }
            if truncation != nil { break }
            offset = end
        }

        if truncation == nil, hitFileCap {
            truncation = .fileCap(limits.matchesPerFile)
        }

        return FileSearchRun(
            query: query,
            root: root,
            files: files,
            // What the index offered, whether or not the run reached it. A
            // capped run says so through `truncation`; overstating the
            // denominator here would be the second lie.
            filesConsidered: paths.count,
            filesScanned: scanned,
            matchCount: matchCount,
            truncation: truncation,
            skippedNames: skipped.sorted(),
            wasRootIndexed: true
        )
    }

    /// Every file path under the root, once, in file order.
    ///
    /// One sequential `forEachEntry` pass per slice. **Not** `relativePath(at:)`
    /// per index: that seeks to the entry's restart point and replays up to 64
    /// front-coded entries, so per-index access is roughly thirty-two times the
    /// decode work of walking the range once. The same lesson is recorded on
    /// `FileCorpus.firstIndex(atOrAfter:)`, where the naive form cost "roughly
    /// twelve hundred decodes" a path.
    private nonisolated static func collectPaths(
        slices: [FileMatcher.Slice],
        cancellation: FileMatcher.Cancellation
    ) -> [String] {
        var paths: [String] = []
        for slice in slices {
            if cancellation.isCancelled { return [] }
            let corpus = slice.corpus
            let range = slice.range ?? 0..<corpus.entryCount
            let prefix = corpus.root
            corpus.forEachEntry(in: range) { index, bytes in
                if cancellation.isCancelled { return false }
                guard !corpus.isDirectory(at: index),
                    !slice.isRemoved(index)
                else { return true }
                let relative = String(decoding: bytes, as: UTF8.self)
                paths.append(prefix + "/" + relative)
                return true
            }
        }
        // File order is the only ordering this feature has, and it is the one
        // Sublime uses. Sorted once here, off the main actor.
        return paths.sorted()
    }

    private nonisolated static func scan(
        paths: [String],
        root: String,
        query: FileSearchQuery,
        needle: [UInt8],
        limits: Limits,
        cancellation: FileMatcher.Cancellation
    ) -> (results: [FileSearchFileResult], scanned: Int) {
        guard !paths.isEmpty else { return ([], 0) }

        let workers = min(
            8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        )
        // Deliberately not every core: this runs while a reader is typing on a
        // laptop, and the picker's matcher made the same choice for the same
        // reason.
        let chunkSize = max(1, (paths.count + workers - 1) / workers)
        let chunkCount = (paths.count + chunkSize - 1) / chunkSize

        var slots = [[FileSearchFileResult]](
            repeating: [], count: chunkCount
        )
        var scannedPerSlot = [Int](repeating: 0, count: chunkCount)

        slots.withUnsafeMutableBufferPointer { slotBuffer in
            scannedPerSlot.withUnsafeMutableBufferPointer { scannedBuffer in
                let slotBase = slotBuffer.baseAddress!
                let scannedBase = scannedBuffer.baseAddress!

                DispatchQueue.concurrentPerform(iterations: chunkCount) {
                    chunk in
                    // First statement on every worker thread. The policy
                    // defaults to *on*, and under it reading a home directory
                    // downloads the user's entire cloud storage. Per thread, so
                    // it is asserted by whoever is reading rather than assumed
                    // from somewhere else.
                    setiopolicy_np(
                        IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                        IOPOL_SCOPE_THREAD,
                        IOPOL_MATERIALIZE_DATALESS_FILES_OFF
                    )

                    let start = chunk * chunkSize
                    let end = min(start + chunkSize, paths.count)
                    guard start < end else { return }

                    // One buffer per worker, reused for every file it reads.
                    // Allocating per file was measured at roughly a
                    // millisecond a file across a 612,221-file run — the read
                    // is not the cost, the setup around it is.
                    let scratch = UnsafeMutableBufferPointer<UInt8>
                        .allocate(capacity: limits.bytesPerFile)
                    defer { scratch.deallocate() }

                    var local: [FileSearchFileResult] = []
                    var scanned = 0
                    for path in paths[start..<end] {
                        if cancellation.isCancelled { break }
                        switch searchOne(
                            path: path, root: root, query: query,
                            needle: needle, limits: limits,
                            scratch: scratch, cancellation: cancellation
                        ) {
                        case .skipped:
                            continue
                        case .scannedNoMatch:
                            scanned += 1
                        case .matched(let result):
                            scanned += 1
                            local.append(result)
                        }
                    }
                    (slotBase + chunk).pointee = local
                    (scannedBase + chunk).pointee = scanned
                }
            }
        }

        return (slots.flatMap { $0 }, scannedPerSlot.reduce(0, +))
    }

    /// Search one file.
    ///
    /// The three outcomes are named rather than collapsed into an optional,
    /// because the middle one carries information: a file read and found empty
    /// is what lets the header say how many files were actually looked at
    /// rather than how many the index offered.
    private nonisolated static func searchOne(
        path: String,
        root: String,
        query: FileSearchQuery,
        needle: [UInt8],
        limits: Limits,
        scratch: UnsafeMutableBufferPointer<UInt8>,
        cancellation: FileMatcher.Cancellation
    ) -> FileSearchOutcome {
        // Raw `stat`, not `ReaderFile.stat`. That one goes through
        // `FileManager.attributesOfItem`, which builds a dictionary of about
        // fifteen keys per call — correct for the one file a reader chose, and
        // measured at roughly a millisecond a file when asked six hundred
        // thousand times. Regular files only: the corpus holds symlinks, and a
        // symlink to a directory would otherwise be opened and read as one.
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else { return .skipped }

        // Size before any read. A cap checked afterwards has already paid the
        // cost it exists to avoid — `ReaderFile.load`'s own argument.
        let size = Int(info.st_size)
        guard size > 0, size <= limits.bytesPerFile else { return .skipped }

        // An indexed path is a claim rather than a guarantee: a deletion this
        // process saw can be resurrected by a newer generation, and a file can
        // go away between the snapshot and the read. Both are skips, not
        // errors — a run that failed because one file moved would be useless.
        let descriptor = path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return .skipped }
        defer { close(descriptor) }

        var filled = 0
        while filled < size {
            let got = read(
                descriptor, scratch.baseAddress! + filled, size - filled
            )
            if got <= 0 { break }
            filled += got
        }
        guard filled > 0 else { return .skipped }

        let bytes = UnsafeBufferPointer<UInt8>(
            start: scratch.baseAddress, count: filled
        )
        guard FileSearchScanner.isProbablyText(bytes) else { return .skipped }

        let found = FileSearchScanner.matchOffsets(
            in: bytes,
            needle: needle,
            isCaseSensitive: query.isCaseSensitive,
            limit: limits.matchesPerFile,
            isCancelled: { cancellation.isCancelled }
        )
        guard !found.offsets.isEmpty else { return .scannedNoMatch }

        let blocks = FileSearchScanner.lines(
            in: bytes,
            matchOffsets: found.offsets,
            needleLength: needle.count,
            contextLines: query.contextLines
        )
        return .matched(
            FileSearchFileResult(
                path: path,
                relativePath: FilePaths.relativePath(
                    of: URL(fileURLWithPath: path),
                    under: URL(fileURLWithPath: root)
                ) ?? path,
                matchCount: found.offsets.count,
                blocks: blocks,
                wasTruncated: found.wasTruncated
            )
        )
    }
}

/// What became of one file.
///
/// `skipped` is binary, oversized, or gone; `scannedNoMatch` was read and held
/// nothing. Keeping them apart is what makes "searched N of M files" true.
private enum FileSearchOutcome {
    case skipped
    case scannedNoMatch
    case matched(FileSearchFileResult)
}
