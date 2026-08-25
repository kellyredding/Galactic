import Foundation

/// Finds a literal string in a file's bytes, and turns byte offsets into
/// numbered lines with context.
///
/// Bytes rather than a `String`, deliberately. Decoding a file before asking
/// whether it contains anything pays for every file that does not, and most
/// files do not. `ReaderFile.load` is the wrong shape to borrow here for that
/// exact reason: it reads the whole file into a `String` and sniffs for a NUL
/// afterwards, which is right for opening one file a reader chose and wrong for
/// walking fifty thousand.
///
/// Nothing here touches the filesystem, so every rule below is testable from a
/// string literal.
enum FileSearchScanner {

    /// Whether these bytes look like text.
    ///
    /// The same window and the same test as `ReaderFile.load`, so a file that
    /// appears in results can be opened and one that cannot be opened never
    /// appears. Two answers to "is this text" is a defect waiting for a file
    /// that straddles them.
    static func isProbablyText(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let window = min(bytes.count, ReaderFile.sniffWindow)
        return memchr(base, 0, window) == nil
    }

    @inline(__always)
    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z' only. Folding beyond ASCII at the byte level is wrong —
        // it needs decoding, which is what this type exists not to do — so a
        // query with non-ASCII letters searches case-sensitively and the doc
        // on `matchOffsets` says so rather than pretending otherwise.
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    /// Every offset at which `needle` occurs.
    ///
    /// Overlapping occurrences all count: advancing by the needle's length
    /// instead of by one byte would under-report `aa` in `aaa`, which is the
    /// kind of wrong answer nobody checks for.
    ///
    /// Case-insensitivity is ASCII-only. A needle containing bytes outside
    /// ASCII is matched exactly whatever `isCaseSensitive` says, because the
    /// alternative is decoding both sides.
    static func matchOffsets(
        in bytes: UnsafeBufferPointer<UInt8>,
        needle: [UInt8],
        isCaseSensitive: Bool,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> (offsets: [Int], wasTruncated: Bool) {
        guard !needle.isEmpty, bytes.count >= needle.count, limit > 0 else {
            return ([], false)
        }

        let fold = !isCaseSensitive
        let wanted: [UInt8] = fold ? needle.map(asciiLower) : needle
        let first = wanted[0]
        // The two byte values that can begin a match. Equal unless folding is
        // on and the first character is a letter.
        let upper: UInt8 = (fold && first >= 97 && first <= 122) ? first - 32 : first
        let last = bytes.count - wanted.count

        guard let base = bytes.baseAddress else { return ([], false) }

        var offsets: [Int] = []
        var i = 0

        // `memchr` for the skip rather than a Swift loop over the buffer.
        // Byte-at-a-time indexing here is bounds-checked, and both apps build
        // this package in Debug for development, so the checked loop is what a
        // reader would actually feel. libc's version is also vectorised.
        return wanted.withUnsafeBufferPointer { needleBuffer -> ([Int], Bool) in
            let needleBase = needleBuffer.baseAddress!
            var sinceCheck = 0
            while i <= last {
                // Throttled: the check takes a lock, and a common first byte
                // brings us back here every few bytes. Per file would be too
                // coarse for a large one; per candidate was measurably silly.
                sinceCheck += 1
                if sinceCheck >= 4_096 {
                    sinceCheck = 0
                    if isCancelled() { return (offsets, false) }
                }

                // Bound each search so a candidate cannot start past `last`.
                let span = last - i + 1
                var at = -1
                if let hit = memchr(base + i, Int32(first), span) {
                    at = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                }
                if upper != first,
                    let hit = memchr(base + i, Int32(upper), span)
                {
                    let other = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    at = at < 0 ? other : min(at, other)
                }
                guard at >= 0 else { return (offsets, false) }

                var matched = true
                if fold {
                    var j = 1
                    while j < wanted.count {
                        if asciiLower(base[at + j]) != needleBase[j] {
                            matched = false
                            break
                        }
                        j += 1
                    }
                } else if wanted.count > 1 {
                    matched =
                        memcmp(base + at + 1, needleBase + 1, wanted.count - 1)
                        == 0
                }

                if matched {
                    offsets.append(at)
                    if offsets.count >= limit { return (offsets, true) }
                }
                // Advance by one, not by the needle's length: overlapping
                // occurrences all count.
                i = at + 1
            }
            return (offsets, false)
        }
    }

    /// Byte offset of the start of every line, plus a sentinel past the end.
    ///
    /// One pass, kept because every match then finds its line by binary search
    /// instead of by re-counting newlines from the top of the file.
    static func lineStarts(in bytes: UnsafeBufferPointer<UInt8>) -> [Int] {
        var starts: [Int] = [0]
        guard let base = bytes.baseAddress else {
            starts.append(bytes.count + 1)
            return starts
        }
        // `memchr` rather than a byte loop, for the same reason as the match
        // scan: this walks the whole file and the checked form is what a Debug
        // build actually runs.
        var i = 0
        while i < bytes.count {
            guard
                let hit = memchr(base + i, 0x0A, bytes.count - i)
            else { break }
            let at = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            starts.append(at + 1)
            i = at + 1
        }
        starts.append(bytes.count + 1)
        return starts
    }

    /// Turn match offsets into numbered lines with context, merging windows
    /// that overlap or touch.
    ///
    /// Touching windows merge so no line is drawn twice. A window with a real
    /// gap after it stays its own block: `contextLines` is the number of lines
    /// asked for, and showing one more to tidy the output would make the
    /// setting mean something other than what it says.
    ///
    /// Line numbers match `SourceRenderer`'s, which splits on newlines and
    /// numbers what it gets — so a trailing newline opens an empty last line
    /// and that line is real. Numbering differently here would put every
    /// number in the results one off from the reader it links into.
    static func lines(
        in bytes: UnsafeBufferPointer<UInt8>,
        matchOffsets: [Int],
        needleLength: Int,
        contextLines: Int
    ) -> [[FileSearchLine]] {
        guard !matchOffsets.isEmpty else { return [] }

        let starts = lineStarts(in: bytes)
        // The sentinel is not a line; `starts.count - 1` is the line count.
        let lineCount = max(1, starts.count - 1)

        // Match offsets ascend, so the line for each is found by walking
        // forward from the last one rather than searching from scratch.
        var columnsByLine: [Int: [Range<Int>]] = [:]
        var lineIndex = 0
        for offset in matchOffsets {
            while lineIndex + 1 < lineCount, starts[lineIndex + 1] <= offset {
                lineIndex += 1
            }
            let lineStart = starts[lineIndex]
            let lineEnd = max(lineStart, starts[lineIndex + 1] - 1)
            let from = offset - lineStart
            // Clamped, because a needle can in principle run past the end of
            // the line it started on.
            let to = min(from + needleLength, lineEnd - lineStart)
            guard to > from else { continue }
            columnsByLine[lineIndex, default: []].append(from..<to)
        }

        let matched = columnsByLine.keys.sorted()
        guard !matched.isEmpty else { return [] }

        // Merge windows. `+ 1` on the adjacency test is what closes a
        // one-line gap.
        var windows: [(low: Int, high: Int)] = []
        for line in matched {
            let low = max(0, line - contextLines)
            let high = min(lineCount - 1, line + contextLines)
            if let last = windows.last, low <= last.high + 1 {
                windows[windows.count - 1].high = max(last.high, high)
            } else {
                windows.append((low, high))
            }
        }

        return windows.map { window in
            (window.low...window.high).map { index in
                let start = starts[index]
                let end = max(start, starts[index + 1] - 1)
                let raw = UnsafeBufferPointer(
                    rebasing: bytes[start..<min(end, bytes.count)]
                )
                return FileSearchLine(
                    line: index + 1,
                    segments: segments(
                        of: raw, columns: columnsByLine[index] ?? []
                    )
                )
            }
        }
    }

    /// Split one line's bytes into matched and unmatched runs.
    private static func segments(
        of bytes: UnsafeBufferPointer<UInt8>,
        columns: [Range<Int>]
    ) -> [FileSearchLine.Segment] {
        // A trailing carriage return is display noise on a CRLF file. Dropped
        // for display only — every offset above was computed against the bytes
        // as they are, so nothing shifts.
        var end = bytes.count
        if end > 0, bytes[end - 1] == 0x0D { end -= 1 }

        func text(_ range: Range<Int>) -> String {
            let clamped =
                min(range.lowerBound, end)..<min(max(range.lowerBound, range.upperBound), end)
            guard !clamped.isEmpty else { return "" }
            let slice = Array(bytes[clamped])
            // Invalid sequences become U+FFFD rather than failing, so one bad
            // byte costs a character and not the line. This is deliberately
            // *not* `ReaderFile`'s whole-file latin-1 fallback: that decision
            // is made per file from the file's own bytes, and one line has too
            // little evidence to make it. A results line is a preview; the
            // reader decodes properly when the file is opened.
            return String(decoding: slice, as: UTF8.self)
        }

        // Sorted and coalesced: two matches can overlap when a needle occurs
        // inside its own previous occurrence, and emitting both would double
        // the characters they share.
        var merged: [Range<Int>] = []
        for column in columns.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, column.lowerBound <= last.upperBound {
                merged[merged.count - 1] =
                    last.lowerBound..<max(last.upperBound, column.upperBound)
            } else {
                merged.append(column)
            }
        }

        // The window this line shows.
        //
        // **A line is not a bounded thing**, and treating it as one is what this
        // fixes. A minified bundle is a single line of several megabytes, and a
        // common word matches inside it — so a search for "README" over 58,086
        // files produced 8.2 MB across 1,063 result lines. That is past the
        // reader's own size cap, so the results page this app had just written
        // could not be opened by it and was handed to the system instead.
        //
        // Centred on the first match rather than taken from the head, because
        // the head of a minified line is never why the line is in the results.
        // A context line has no match to centre on and shows its head, which is
        // where a reader looks anyway.
        var lo = 0
        var hi = end
        if end > maxLineBytes {
            if let first = merged.first {
                lo = max(0, first.lowerBound - maxLineBytes / 3)
                hi = min(end, lo + maxLineBytes)
                lo = max(0, min(lo, hi - maxLineBytes))
            } else {
                hi = maxLineBytes
            }
        }

        var result: [FileSearchLine.Segment] = []
        if lo > 0 { result.append(.init(text: "…", isMatch: false)) }

        var cursor = lo
        for column in merged {
            // **Bounds first, then the guard, then the range.** A line can match
            // more than once and the window is centred on the first, so a later
            // match can sit entirely outside it — and building the range before
            // checking it constructs `5006..<480`, which traps where it is
            // written rather than failing the guard on the next line.
            let clipLo = max(column.lowerBound, lo)
            let clipHi = min(column.upperBound, hi)
            guard clipLo < clipHi else { continue }
            if clipLo > cursor {
                let before = text(cursor..<clipLo)
                if !before.isEmpty {
                    result.append(.init(text: before, isMatch: false))
                }
            }
            let hit = text(clipLo..<clipHi)
            if !hit.isEmpty { result.append(.init(text: hit, isMatch: true)) }
            cursor = max(cursor, clipHi)
        }
        if cursor < hi {
            let after = text(cursor..<hi)
            if !after.isEmpty {
                result.append(.init(text: after, isMatch: false))
            }
        }
        if hi < end { result.append(.init(text: "…", isMatch: false)) }
        return result
    }

    /// How much of one line a result may show, in bytes.
    ///
    /// Bytes rather than characters because the window is chosen against the
    /// raw buffer and the decode happens after it.
    static let maxLineBytes = 480
}

// MARK: - Array conveniences

extension FileSearchScanner {
    /// Test and call-site convenience. The engine works from a mapped buffer;
    /// everything else has an array.
    static func withBytes<T>(
        _ array: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> T
    ) -> T {
        array.withUnsafeBufferPointer { body($0) }
    }
}
