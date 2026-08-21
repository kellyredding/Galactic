import Foundation

/// Where a query's tokens best sit in a candidate, and what that is worth.
///
/// ### Why one greedy pass was not enough
///
/// The pass this replaces aligned left to right, taking each character at the
/// earliest position that would accept it, and scored that one alignment. So
/// `linear-cli` spent `l`, `i`, `n`, `e` on `kajabi-fiLes/agent-guIdeliNEs`
/// and reached the filename with only `ar-cli` left to place — forfeiting the
/// contiguity awards *and* `basenameBonus`, which is gated on the match
/// falling after the last separator. The row holding the query as a literal
/// substring in its own name was the row denied the bonus written for it.
/// Measured, the same basename scored 246 or 153 depending only on what the
/// directories above it happened to spell.
///
/// ### Leftmost and rightmost, and why not more than that
///
/// The repair is to score the **rightmost** alignment as well and keep the
/// better. Rightmost is what pulls a run onto the filename, because a
/// filename is at the end; leftmost still wins where the query names a
/// directory near the front. Two passes, no allocation, and between them they
/// cover every case observed here.
///
/// A middle alignment better than both ends is possible in principle —
/// `xlxixnxe/line/xlxixnxe.md` against `line` — and is deliberately not
/// found. Reaching it means either scanning every occurrence, which is
/// quadratic per candidate, or a dynamic-programming table per candidate,
/// which is what fzf's second algorithm does. Neither fits the budget below.
///
/// ### The budget this lives inside
///
/// One keystroke scores every entry the prefilter admits — on this machine,
/// most of 881,226. **Measured: the pass is 4–8 ms and an earlier draft of
/// this file was 655 ms**, a hundredfold, entirely from allocating a
/// positions array per candidate. So nothing here allocates, nothing here
/// takes an array of arrays, and the query arrives as one flat buffer with a
/// length per token. `positions(…)` is the one exception and it runs for the
/// hundred rows that are displayed.
///
/// ### Why the scorer and the highlighter share this
///
/// They used to each carry a copy of the walk, and the copies drifted: the
/// picker highlighted letters the score had not been computed from. They
/// share the rule rather than the resulting offsets, deliberately — the
/// highlighter runs against a display string that may be trimmed to a browse
/// root and is indexed by character, so the scan's byte positions would not
/// address it.
enum FileMatchAlignment {

    // MARK: - Scoring weights

    /// Any matched character. The unit the other weights are proportioned
    /// against, kept large so the bonuses can be integers.
    static let matchScore = 16
    /// A character landing at the start of a path segment or a word inside
    /// one.
    static let wordStartBonus = 8
    /// A character that continues an unbroken run.
    static let contiguousBonus = 4
    /// Skipping characters costs, or spreading a query across a path would be
    /// free. Without these, `n/o/t/e/s/unrelated.md` beat `notes.md` for the
    /// query `notes`: every letter landed after a `/` and collected a
    /// word-start bonus, and nothing charged for the distance between them.
    ///
    /// Charged **within** a token only. The gap between two tokens is free,
    /// and that is the whole content of what a space in the query means.
    static let gapStartPenalty = 3
    static let gapExtensionPenalty = 1
    /// Deducted per character skipped before the first match, capped so a long
    /// path cannot drive a real match negative.
    static let maxLeadingPenalty = 12
    /// Awarded when the whole query matched inside the file's own name rather
    /// than being spread across the directories above it.
    ///
    /// The structural fix for the same problem the gap penalties address, and
    /// the more honest one: someone typing `notes` means a file called notes,
    /// not five directories whose initials spell it. Large enough to be
    /// decisive, which is the point — VS Code separates these into two scoring
    /// tiers for the same reason.
    static let basenameBonus = 40

    // MARK: - Scoring

    /// The best of the two alignments, or nil when the tokens do not fit.
    ///
    /// - Parameters:
    ///   - needle: every token's bytes, concatenated.
    ///   - lengths: one length per token, in the order typed.
    static func score(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> Int? {
        let separator = lastSeparator(in: candidate)
        guard
            let leftmost = scoreLeftmost(
                needle: needle, lengths: lengths, in: candidate,
                caseSensitive: caseSensitive, lastSeparator: separator
            )
        else { return nil }

        // Cannot fail once leftmost succeeded — a subsequence read backwards
        // is still a subsequence — but the optional keeps that an assertion
        // rather than a trap.
        guard
            let rightmost = scoreRightmost(
                needle: needle, lengths: lengths, in: candidate,
                caseSensitive: caseSensitive, lastSeparator: separator
            )
        else { return leftmost }

        return max(leftmost, rightmost)
    }

    /// Each token as early as it will go — the pass that defines whether a
    /// candidate matches at all, since greedy-earliest finds a subsequence
    /// whenever one exists.
    private static func scoreLeftmost(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool,
        lastSeparator separator: Int
    ) -> Int? {
        var total = 0
        var cursor = 0
        var previous = -1
        var first = -1
        var offset = 0

        for token in 0..<lengths.count {
            let length = lengths[token]
            var index = 0
            var position = cursor

            while position < candidate.count, index < length {
                if folded(candidate[position], caseSensitive)
                    == needle[offset + index]
                {
                    total += matchScore
                    if position == 0 || isBoundary(candidate[position - 1]) {
                        total += wordStartBonus
                    }
                    if index == 0 {
                        // A token's first character takes no contiguity award
                        // and no gap charge: the distance from the previous
                        // token is the space the reader typed.
                        if first < 0 {
                            first = position
                            total -= min(position, maxLeadingPenalty)
                        }
                    } else if position == previous + 1 {
                        total += contiguousBonus
                    } else {
                        total -=
                            gapStartPenalty
                            + (position - previous - 2) * gapExtensionPenalty
                    }
                    previous = position
                    index += 1
                }
                position += 1
            }
            guard index == length else { return nil }
            cursor = previous + 1
            offset += length
        }

        if first > separator { total += basenameBonus }
        return total
    }

    /// Each token as late as it will go.
    ///
    /// The pass that fixes the measured defect: a filename sits at the end of
    /// a path, so taking every character as late as possible is what lands the
    /// run on the filename instead of leaving its head scattered through the
    /// directories above.
    private static func scoreRightmost(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool,
        lastSeparator separator: Int
    ) -> Int? {
        var total = 0
        var cursor = candidate.count - 1
        var next = -1
        var offset = needle.count

        for token in (0..<lengths.count).reversed() {
            let length = lengths[token]
            offset -= length
            var index = length - 1
            var position = cursor

            while position >= 0, index >= 0 {
                if folded(candidate[position], caseSensitive)
                    == needle[offset + index]
                {
                    total += matchScore
                    if position == 0 || isBoundary(candidate[position - 1]) {
                        total += wordStartBonus
                    }
                    if index == length - 1 {
                        // The token's last character. Whatever follows it
                        // belongs to the next token, so no award and no charge.
                    } else if position == next - 1 {
                        total += contiguousBonus
                    } else {
                        total -=
                            gapStartPenalty
                            + (next - position - 2) * gapExtensionPenalty
                    }
                    next = position
                    index -= 1
                }
                position -= 1
            }
            guard index < 0 else { return nil }
            cursor = next - 1
        }

        // `next` ended on the first token's first character, which is the
        // lowest matched position — what both remaining terms are about.
        total -= min(next, maxLeadingPenalty)
        if next > separator { total += basenameBonus }
        return total
    }

    // MARK: - Highlighting

    /// The positions the winning alignment matched, ascending.
    ///
    /// Allocates, and is allowed to: it runs for the rows on screen rather
    /// than for every entry in the index. It re-walks rather than receiving
    /// the scan's answer because the string being highlighted is not the one
    /// that was scanned — see the type's note above.
    static func positions(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> [Int]? {
        let separator = lastSeparator(in: candidate)
        guard
            let leftmost = scoreLeftmost(
                needle: needle, lengths: lengths, in: candidate,
                caseSensitive: caseSensitive, lastSeparator: separator
            )
        else { return nil }
        let rightmost = scoreRightmost(
            needle: needle, lengths: lengths, in: candidate,
            caseSensitive: caseSensitive, lastSeparator: separator
        )

        // The same comparison `score(…)` makes, so the letters highlighted are
        // the letters the score was computed from.
        if let rightmost, rightmost > leftmost {
            return rightmostPositions(
                needle: needle, lengths: lengths, in: candidate,
                caseSensitive: caseSensitive
            )
        }
        return leftmostPositions(
            needle: needle, lengths: lengths, in: candidate,
            caseSensitive: caseSensitive
        )
    }

    private static func leftmostPositions(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> [Int]? {
        var found: [Int] = []
        found.reserveCapacity(needle.count)
        var cursor = 0
        var offset = 0

        for token in 0..<lengths.count {
            let length = lengths[token]
            var index = 0
            var position = cursor
            while position < candidate.count, index < length {
                if folded(candidate[position], caseSensitive)
                    == needle[offset + index]
                {
                    found.append(position)
                    cursor = position + 1
                    index += 1
                }
                position += 1
            }
            guard index == length else { return nil }
            offset += length
        }
        return found
    }

    private static func rightmostPositions(
        needle: UnsafeBufferPointer<UInt8>,
        lengths: UnsafeBufferPointer<Int>,
        in candidate: UnsafeBufferPointer<UInt8>,
        caseSensitive: Bool
    ) -> [Int]? {
        var found: [Int] = []
        found.reserveCapacity(needle.count)
        var cursor = candidate.count - 1
        var offset = needle.count

        for token in (0..<lengths.count).reversed() {
            let length = lengths[token]
            offset -= length
            var index = length - 1
            var position = cursor
            while position >= 0, index >= 0 {
                if folded(candidate[position], caseSensitive)
                    == needle[offset + index]
                {
                    found.append(position)
                    cursor = position - 1
                    index -= 1
                }
                position -= 1
            }
            guard index < 0 else { return nil }
        }
        // Collected from the last token's last character downwards, so this is
        // strictly descending.
        return found.reversed()
    }

    // MARK: - Bytes

    @inline(__always)
    static func folded(_ byte: UInt8, _ caseSensitive: Bool) -> UInt8 {
        if !caseSensitive, byte >= 0x41, byte <= 0x5A { return byte | 0x20 }
        return byte
    }

    @inline(__always)
    static func isBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x2F, 0x5F, 0x2D, 0x2E, 0x20: return true  // / _ - . space
        default: return false
        }
    }

    /// The last `/` in the candidate.
    ///
    /// The whole candidate, rather than the last one seen before the match
    /// ended — which is what the pass this replaces compared against, and it
    /// was an approximation that disagreed with its own documentation. Under
    /// it, `docs` matching the *directory* in `docs/notes.md` collected the
    /// bonus for having matched inside a filename, because the separator after
    /// it had not been reached yet. Scanning backwards costs a basename.
    @inline(__always)
    private static func lastSeparator(
        in candidate: UnsafeBufferPointer<UInt8>
    ) -> Int {
        var position = candidate.count - 1
        while position >= 0 {
            if candidate[position] == 0x2F { return position }
            position -= 1
        }
        return -1
    }
}
