import Foundation
import os

/// Ranks a `FileCorpus` against a query.
///
/// Six things separate this from the pass it replaces, and only one of them is
/// parallelism:
///
/// 1. **A bitmask prefilter.** One `&` per candidate where the old pass walked
///    the whole path once per distinct query character.
/// 2. **Bytes, not strings.** Nothing is allocated per candidate. The old pass
///    allocated twice — `Array(candidate.lowercased())` — roughly 628,000
///    times per keystroke.
/// 3. **Bounded selection.** The old pass sorted every match to show a hundred
///    rows. The query `rme` matches 255,589 paths on this machine.
/// 4. **Cancellation that stops work**, rather than only discarding its result.
/// 5. **Per-worker scratch**, reused across candidates.
/// 6. **Bounded parallelism** over restart-aligned chunks.
///
/// Measured against the same corpus: 443–827 ms becomes 4–8 ms.
public enum FileMatcher {

    /// One corpus to scan, and the entries in it that no longer exist.
    ///
    /// The index is several shards plus a small in-memory corpus of files
    /// created since the last walk, and removals are recorded as a bitset per
    /// shard rather than by rewriting one. That keeps a delete O(log n) — find
    /// the entry, set a bit — instead of rewriting twenty megabytes because
    /// one file went away.
    public struct Slice {
        public let corpus: FileCorpus
        /// One bit per entry; set means the entry has been deleted since the
        /// shard was written. Nil when nothing has been removed.
        public let removed: [UInt64]?
        /// The entries worth scanning, when only part of this corpus is in
        /// scope — browsing a directory inside an already-indexed root.
        ///
        /// Per slice rather than one range for all of them, because the shards
        /// of a root are separate corpora: a subtree lands wholly inside one
        /// of them and is absent from every other, so a single range applied
        /// to all would be meaningless.
        public let range: Range<Int>?

        public init(
            corpus: FileCorpus, removed: [UInt64]? = nil,
            range: Range<Int>? = nil
        ) {
            self.corpus = corpus
            self.removed = removed
            self.range = range
        }

        @inline(__always)
        func isRemoved(_ index: Int) -> Bool {
            guard let removed else { return false }
            let word = index >> 6
            guard word < removed.count else { return false }
            return removed[word] & (1 << UInt64(index & 63)) != 0
        }
    }

    public struct Match {
        /// Which slice the entry came from.
        public let slice: Int
        public let index: Int
        /// How well the query sits in the candidate, and nothing else.
        ///
        /// Depth and recency used to be folded in here, which gave them an
        /// exchange rate against placement that nobody chose: a twelve-point
        /// recency bonus outranked a two-level depth difference, and a
        /// four-point-per-level depth penalty overturned the distinction
        /// between a word start and a mid-word containment by one point. They
        /// are ordered tiers in `better(_:than:)` now, so neither can
        /// overturn a genuinely better placement.
        public let score: Int
        /// Path separators in the candidate. Fewer is better — a shallower
        /// match is the one more likely meant, and ranking the deep copies of
        /// a file above the shallow original teaches a reader to scroll when
        /// they should be re-rooting.
        let depth: Int
        /// Up to `maxRecencyBonus`. Its own doc comment always claimed recency
        /// breaks ties rather than outranking a better name match; as a tier
        /// below placement and depth, that is finally true.
        let recency: Int
        /// The candidate's byte length, carried rather than looked up.
        ///
        /// It is the second tiebreak, so a comparator would otherwise decode
        /// the entry to ask — and a front-coded entry can only be decoded by
        /// replaying its whole restart block. The scan already has the length
        /// in hand, so carrying it turns a sixty-four-step decode per
        /// comparison into a field read.
        let length: Int
    }

    /// Cancellation, in the shape that works.
    ///
    /// Setting a flag the running pass never reads is what produced the CPU
    /// peg this type exists to remove: `Task.cancel()` stopped the *await*,
    /// not the loop, so sixty-three full passes ran to completion at once.
    ///
    /// Checked once per restart block rather than per candidate. Sixty-four
    /// entries is finer than it needs to be — a whole block is a few
    /// microseconds — and it keeps the check out of the inner loop entirely.
    public final class Cancellation: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        public init() {}
        public func cancel() { state.withLock { $0 = true } }
        public var isCancelled: Bool { state.withLock { $0 } }
    }

    // MARK: - Scoring weights

    /// Placement and contiguity are weighed by `FileMatchAlignment`, which is
    /// where the alignment they describe is chosen. This one stays here
    /// because it is not a property of the alignment at all.
    ///
    /// The most a recently-touched file can gain. Deliberately small against a
    /// well-placed character: recency breaks ties, it does not outrank a
    /// better name match.
    private static let maxRecencyBonus = 12

    // MARK: - Entry point

    /// - Parameter includingDirectories: whether directory entries can be
    ///   offered as results. Off by default, and the distinction matters
    ///   because the two questions have different answers: the corpus holds
    ///   directories so that re-rooting and path completion can be answered
    ///   from memory, while a picker that opens files into a reader has
    ///   nothing to do with a directory row.
    public static func matches(
        in corpus: FileCorpus,
        range: Range<Int>? = nil,
        query: String,
        limit: Int,
        includingDirectories: Bool = false,
        cancellation: Cancellation? = nil
    ) -> [Match] {
        matches(
            in: [Slice(corpus: corpus)],
            range: range,
            query: query,
            limit: limit,
            includingDirectories: includingDirectories,
            cancellation: cancellation
        )
    }

    /// Scan several corpora as one.
    ///
    /// Work is flattened into chunks across *all* slices before it is handed
    /// out, rather than a slice at a time. A root divides into shards of wildly
    /// different sizes — one holding four hundred thousand entries next to one
    /// holding nine — and scheduling per slice would leave most workers idle
    /// waiting for the largest.
    public static func matches(
        in slices: [Slice],
        range: Range<Int>? = nil,
        query: String,
        limit: Int,
        includingDirectories: Bool = false,
        cancellation: Cancellation? = nil
    ) -> [Match] {
        let prepared = PreparedQuery(query)
        guard !prepared.isEmpty, !slices.isEmpty else { return [] }

        var chunks: [(slice: Int, range: Range<Int>)] = []
        for (position, slice) in slices.enumerated() {
            let scope = slice.range ?? range ?? 0..<slice.corpus.entryCount
            let bounded = scope.clamped(to: 0..<slice.corpus.entryCount)
            guard !bounded.isEmpty else { continue }
            for piece in chunkRanges(of: bounded, in: slice.corpus) {
                chunks.append((position, piece))
            }
        }
        guard !chunks.isEmpty else { return [] }
        var perChunk = [[Match]](repeating: [], count: chunks.count)

        perChunk.withUnsafeMutableBufferPointer { results in
            // The base address rather than the buffer itself, because
            // `concurrentPerform` takes an escaping closure and an `inout`
            // buffer cannot be captured by one. Each worker writes its own
            // slot and no two slots overlap, so the aliasing this sidesteps
            // is the compiler's concern rather than a real one.
            let slots = results.baseAddress!
            let work: (Int) -> Void = { position in
                let work = chunks[position]
                slots[position] = scan(
                    slice: work.slice,
                    in: slices[work.slice],
                    range: work.range,
                    query: prepared,
                    limit: limit,
                    includingDirectories: includingDirectories,
                    cancellation: cancellation
                )
            }
            if chunks.count == 1 {
                work(0)
            } else {
                DispatchQueue.concurrentPerform(
                    iterations: chunks.count, execute: work
                )
            }
        }

        // Merging is a sort of at most `workers × limit` elements — a few
        // hundred — where sorting the matches themselves would be a quarter of
        // a million.
        return
            perChunk
            .flatMap { $0 }
            .sorted { better($0, than: $1) }
            .prefix(limit)
            .map { $0 }
    }

    /// Placement, then depth, then recency, then the shorter path, then
    /// alphabetically.
    ///
    /// Ordered tiers rather than one sum, because the terms are not
    /// commensurable and pretending they were produced two measured wrongs:
    /// recency decided between two identically-placed matches five levels
    /// apart, and an additive depth penalty flipped a word start below a
    /// mid-word containment. A tier can only speak when everything above it
    /// is silent, which is what each of these was always documented to do.
    ///
    /// The corpus is sorted, so a lower index *is* alphabetically earlier —
    /// which makes the last tiebreak an integer comparison rather than a
    /// string one, and keeps the order stable between identical queries.
    private static func better(_ left: Match, than right: Match) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.depth != right.depth { return left.depth < right.depth }
        if left.recency != right.recency { return left.recency > right.recency }
        if left.length != right.length { return left.length < right.length }
        if left.slice != right.slice { return left.slice < right.slice }
        return left.index < right.index
    }

    /// Split a range into restart-aligned chunks, one per worker.
    ///
    /// Aligned because a front-coded entry can only be decoded from a whole
    /// one, so a chunk that began mid-block would have nothing to reconstruct
    /// from.
    private static func chunkRanges(
        of scope: Range<Int>, in corpus: FileCorpus
    ) -> [Range<Int>] {
        // Below this a single pass is faster than handing work to other cores.
        let parallelThreshold = 20_000
        guard scope.count >= parallelThreshold else { return [scope] }

        // Deliberately not every core. The picker runs while the reader is
        // typing on a laptop, and the measured gain past this is small against
        // the cost of taking the machine over — which is the failure this
        // whole effort started from.
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let stride =
            max(1, (scope.count / workers) / FileCorpus.restartInterval + 1)
            * FileCorpus.restartInterval

        var ranges: [Range<Int>] = []
        var start = scope.lowerBound
        while start < scope.upperBound {
            let end = min(start + stride, scope.upperBound)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    // MARK: - The scan

    private static func scan(
        slice: Int,
        in target: Slice,
        range: Range<Int>,
        query: PreparedQuery,
        limit: Int,
        includingDirectories: Bool,
        cancellation: Cancellation?
    ) -> [Match] {
        let corpus = target.corpus
        var best = BoundedSelection(limit: limit)
        let today = FileCorpus.today
        var sinceCheck = 0
        var stopped = false

        // The query's buffers are borrowed once for the whole chunk rather
        // than per candidate. Taking them inside the loop would put an
        // exclusivity check and a retain on the hot path, which over most of a
        // million entries is not a rounding error — see `FileMatchAlignment`
        // on the hundredfold this file has already paid once.
        query.needle.withUnsafeBufferPointer { needle in
            query.tokenLengths.withUnsafeBufferPointer { lengths in
                corpus.forEachEntry(in: range) { index, bytes in
                    if sinceCheck >= FileCorpus.restartInterval {
                        sinceCheck = 0
                        if cancellation?.isCancelled == true {
                            stopped = true
                            return false
                        }
                    }
                    sinceCheck += 1

                    // Deleted since the shard was written. Checked before
                    // anything else, because a removed entry must be invisible
                    // rather than merely ranked low.
                    if target.isRemoved(index) { return true }
                    if !includingDirectories, corpus.isDirectory(at: index) {
                        return true
                    }
                    let bag = corpus.bags[index]
                    guard FileCharBag.isSuperset(bag, of: query.bag) else {
                        return true
                    }

                    let hasNonASCII = bag & FileCharBag.nonASCIIBit != 0
                    let score: Int?
                    if hasNonASCII && !query.diacriticSensitive {
                        score = foldedScore(
                            of: bytes, needle: needle, lengths: lengths,
                            caseSensitive: query.caseSensitive
                        )
                    } else {
                        score = FileMatchAlignment.score(
                            needle: needle, lengths: lengths, in: bytes,
                            caseSensitive: query.caseSensitive
                        )
                    }
                    guard let total = score else { return true }

                    // Placement is the first tier, so a candidate scoring
                    // below every survivor cannot place however shallow or
                    // fresh it is — and asking those two questions of it is
                    // then pure waste. Measured on `rme`, which matches
                    // 255,589 entries and keeps almost none of them: 18.0 ms
                    // mean without this guard, 11.6 with it.
                    if best.isFull, total < best.worstScore { return true }

                    best.offer(
                        Match(
                            slice: slice, index: index, score: total,
                            depth: FileMatchAlignment.separatorCount(
                                in: bytes
                            ),
                            recency: recencyBonus(
                                days: corpus.modifiedDays[index], today: today
                            ),
                            length: bytes.count
                        )
                    )
                    return true
                }
            }
        }

        return stopped ? [] : best.sorted()
    }

    /// The path for entries carrying accents, when the query did not.
    ///
    /// Folding changes byte lengths, so this cannot run in the byte loop —
    /// but it runs for a vanishing fraction of a real tree, and only when the
    /// reader typed plain letters for an accented name, which is exactly the
    /// case they expect to work.
    private static func foldedScore(
        of bytes: UnsafeBufferPointer<UInt8>,
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        caseSensitive: Bool
    ) -> Int? {
        let text = String(decoding: bytes, as: UTF8.self)
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil
        )
        let scratch = Array(folded.utf8)
        return scratch.withUnsafeBufferPointer {
            FileMatchAlignment.score(
                needle: needle, lengths: lengths, in: $0,
                caseSensitive: caseSensitive
            )
        }
    }

    /// Up to `maxRecencyBonus`, decaying by a point a week.
    @inline(__always)
    private static func recencyBonus(days: UInt16, today: UInt16) -> Int {
        guard today >= days else { return maxRecencyBonus }
        let age = Int(today - days)
        return max(0, maxRecencyBonus - age / 7)
    }

    // MARK: - Query

    /// A query resolved once for a pass over many candidates.
    public struct PreparedQuery {
        /// Every token's bytes, concatenated.
        ///
        /// Flat, with `tokenLengths` carrying the divisions, rather than an
        /// array of arrays. The scan touches this once per candidate across
        /// most of a million of them, and an array of arrays would retain and
        /// release an inner array every time.
        let needle: [UInt8]
        /// One length per whitespace-separated run, in the order typed.
        ///
        /// Ordered and non-overlapping: a later token is placed after the
        /// previous one ends. A space therefore still means "then, somewhere
        /// later" — which is what it has always meant here, except that it
        /// used to mean it by being *deleted*, which cost the runs either side
        /// their contiguity. Measured, that made typing the space strictly
        /// worse than eliding it: `linear cli` scored a path holding
        /// `linear-cli` below what `linear-cli` scored it.
        let tokenLengths: [Int]
        /// The union of every token's characters.
        ///
        /// The same characters the condensed needle had, minus a space, which
        /// never had a bit worth having — so tokenizing cannot narrow the
        /// prefilter, which is what keeps the match set unchanged.
        let bag: UInt64
        /// Any uppercase in the query makes the whole query case-sensitive —
        /// ripgrep's rule, and what a reader's fingers already expect.
        let caseSensitive: Bool
        /// The same rule for accents: type it plain and `café` matches; type
        /// the accent and only `café` does. One idea, applied twice, rather
        /// than two rules to remember.
        let diacriticSensitive: Bool

        var isEmpty: Bool { tokenLengths.isEmpty }

        public init(_ query: String) {
            let runs = query.split(whereSeparator: { $0.isWhitespace })
            caseSensitive = runs.contains { $0.contains { $0.isUppercase } }
            diacriticSensitive = runs.contains {
                $0.unicodeScalars.contains { $0.value > 127 }
            }

            var flat: [UInt8] = []
            var divisions: [Int] = []
            for run in runs {
                let normalised =
                    diacriticSensitive
                    ? String(run)
                    : String(run).folding(
                        options: [.diacriticInsensitive], locale: nil
                    )
                let bytes = Array(
                    (caseSensitive ? normalised : normalised.lowercased()).utf8
                )
                guard !bytes.isEmpty else { continue }
                flat.append(contentsOf: bytes)
                divisions.append(bytes.count)
            }
            needle = flat
            tokenLengths = divisions
            bag = FileCharBag.bag(of: flat)
        }
    }

    // MARK: - Bounded selection

    /// Keeps the best `limit` matches without sorting the rest.
    ///
    /// A binary heap ordered worst-first: once it is full, a candidate is
    /// compared against the worst survivor and discarded in one comparison if
    /// it loses. Memory is `limit` per worker rather than one entry per match.
    private struct BoundedSelection {
        private var heap: [Match] = []
        private let limit: Int

        init(limit: Int) {
            self.limit = max(1, limit)
            // Clamped, because a caller asking for everything passes
            // `Int.max` and reserving that overflows before it allocates.
            heap.reserveCapacity(min(self.limit, 4_096))
        }

        private func isWorse(_ left: Match, _ right: Match) -> Bool {
            better(right, than: left)
        }

        var isFull: Bool { heap.count >= limit }

        /// The lowest score among the survivors.
        ///
        /// The root is the worst element by the whole comparator, and score is
        /// its first tier, so nothing in the heap scores lower than the root.
        var worstScore: Int { heap[0].score }

        mutating func offer(_ candidate: Match) {
            if heap.count < limit {
                heap.append(candidate)
                siftUp(from: heap.count - 1)
            } else if isWorse(heap[0], candidate) {
                heap[0] = candidate
                siftDown(from: 0)
            }
        }

        private mutating func siftUp(from start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                var worst = parent
                for child in [2 * parent + 1, 2 * parent + 2]
                where child < heap.count && isWorse(heap[child], heap[worst]) {
                    worst = child
                }
                if worst == parent { return }
                heap.swapAt(parent, worst)
                parent = worst
            }
        }

        func sorted() -> [Match] { heap }
    }
}

extension FileMatcher {

    /// Character offsets into `display` that the query matched, for
    /// highlighting.
    ///
    /// Deliberately not computed during the scan. Folding an accented name
    /// changes both byte lengths and character counts, so offsets taken
    /// against the folded form would highlight the wrong letters — and
    /// carrying a mapping through the hot loop would cost every candidate for
    /// the benefit of the hundred that are shown.
    ///
    /// So the scan answers *whether* and *how well*, and this answers *where*,
    /// for the rows that survived.
    ///
    /// **It runs the same alignment the score came from.** It used to walk
    /// greedily on its own, which meant the picker highlighted one alignment
    /// and ranked by another — the same defect twice, and the visible half of
    /// it. Sharing the routine rather than carrying the scan's offsets is
    /// deliberate: `display` may have been trimmed to a browse root and is
    /// indexed by character, so the scan's byte positions do not address it.
    public static func highlightOffsets(in display: String, query: PreparedQuery)
        -> [Int]
    {
        guard !query.isEmpty else { return [] }

        // The map is built alongside the folded bytes rather than
        // reconstructed after. Folding can change a character's byte length,
        // which is exactly why the two cannot be assumed to correspond.
        var bytes: [UInt8] = []
        var characterOfByte: [Int] = []
        bytes.reserveCapacity(display.utf8.count)
        characterOfByte.reserveCapacity(display.utf8.count)

        for (index, character) in display.enumerated() {
            var piece = String(character)
            if !query.diacriticSensitive {
                piece = piece.folding(
                    options: [.diacriticInsensitive], locale: nil
                )
            }
            if !query.caseSensitive { piece = piece.lowercased() }
            for byte in piece.utf8 {
                bytes.append(byte)
                characterOfByte.append(index)
            }
        }

        let matched = bytes.withUnsafeBufferPointer { candidate in
            query.needle.withUnsafeBufferPointer { needle in
                query.tokenLengths.withUnsafeBufferPointer { lengths in
                    FileMatchAlignment.positions(
                        needle: needle, lengths: lengths, in: candidate,
                        caseSensitive: query.caseSensitive
                    )
                }
            }
        }
        // No alignment means the display string and the scanned entry
        // disagree, which a length-changing fold can produce. Nothing
        // highlighted is better than the wrong letters highlighted.
        guard let matched else { return [] }

        var seen = Set<Int>()
        return matched
            .map { characterOfByte[$0] }
            .filter { seen.insert($0).inserted }
    }
}
