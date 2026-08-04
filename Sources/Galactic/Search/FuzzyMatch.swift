import Foundation

/// Subsequence matching with a relevance score.
///
/// Named for what it does rather than where it started: it began life matching
/// keystroke labels, and matches prose bodies just as well.
///
/// Written for short corpora — a list of labels, or bodies measured in lines —
/// so ranking quality matters and asymptotics do not: this walks the candidate
/// once per query rather than reaching for anything cleverer. A host matching
/// against something large wants an index, not this.
public enum FuzzyMatch {

    /// A successful match: how good it was, and where it landed.
    public struct Result: Equatable {
        public let score: Int
        /// Character offsets into the candidate that matched, ascending. Empty
        /// for an empty query, which matches everything and highlights nothing.
        public let matchedOffsets: [Int]
    }

    /// How a query is read.
    public enum Scope {
        /// The whole query is one subsequence: its characters must appear in
        /// order, with any gaps. "mti" matches "Move to Icebox".
        ///
        /// Right for short labels, where the words are few and initials are how
        /// people abbreviate them. Wrong for prose — over a paragraph, a
        /// gap-anywhere subsequence matches nearly everything.
        case subsequence

        /// Whitespace-separated terms, each matched *contiguously*, in order,
        /// with any gap between them — a space behaves like `.*` in a regex.
        ///
        /// So "the" is one literal and matches "another" but not "three"; while
        /// "th e" is `th` followed later by `e` and matches "three", because the
        /// `e` comes after the `th`. Ordering is what makes the difference: a
        /// note reading "test item … This is a thing" has both fragments but the
        /// `e` precedes the `th`, so it correctly does not match.
        case terms
    }

    /// Points for a character that continues an unbroken run from the previous
    /// match. Runs are the strongest signal that the query is a prefix or
    /// substring rather than letters scattered across the string.
    private static let contiguousBonus = 8
    /// Points for a character landing at the start of a word.
    private static let wordStartBonus = 6
    /// Points for any matched character, so a longer match beats a shorter one
    /// when neither has structure to recommend it.
    private static let matchScore = 2
    /// Deducted per character skipped before the first match, so an earlier hit
    /// wins between two otherwise equal candidates. Capped so a long tail cannot
    /// drive a real match negative.
    private static let leadingPenalty = 1
    private static let maxLeadingPenalty = 12

    /// Match `candidate` against `query`, or nil when it does not match under
    /// `scope`. Case-insensitive. An empty query succeeds with a zero score and
    /// no offsets, so an unfiltered list shows everything.
    public static func result(
        _ candidate: String, query: String, scope: Scope = .subsequence
    ) -> Result? {
        switch scope {
        case .subsequence:
            return spanning(candidate, query: query)
        case .terms:
            return orderedTerms(candidate, query: query)
        }
    }

    /// Each term found contiguously, in order, each after the last.
    ///
    /// One forward pass with a cursor — no backtracking. That is a real
    /// limitation worth naming: a query whose earlier term has several
    /// occurrences commits to the first one. That cannot cost a *match* —
    /// an earlier start leaves at least as much room for the terms after it —
    /// but it can cost *score*, since the occurrence taken may not be the one
    /// sitting at a word start. For a search box the user watches while
    /// typing, that is a fair trade for predictability.
    private static func orderedTerms(
        _ candidate: String, query: String
    ) -> Result? {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { Array($0.lowercased()) }
        guard !terms.isEmpty else {
            return Result(score: 0, matchedOffsets: [])
        }

        let hay = Array(candidate.lowercased())
        var cursor = 0
        var total = 0
        var offsets: [Int] = []

        for needle in terms {
            guard let at = firstOccurrence(of: needle, in: hay, from: cursor)
            else { return nil }
            offsets.append(contentsOf: at..<(at + needle.count))
            // A longer literal is a stronger signal than a short one, and a
            // contiguous run is the whole premise here, so every term earns the
            // run bonus.
            total += needle.count * matchScore + contiguousBonus
            if isWordStart(hay, at) { total += wordStartBonus }
            total -= min((at - cursor) * leadingPenalty, maxLeadingPenalty)
            cursor = at + needle.count
        }

        return Result(score: total, matchedOffsets: offsets)
    }

    /// The first index at or after `from` where `needle` sits contiguously.
    private static func firstOccurrence(
        of needle: [Character], in hay: [Character], from: Int
    ) -> Int? {
        guard !needle.isEmpty, hay.count - from >= needle.count else {
            return nil
        }
        for start in from...(hay.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count
            where hay[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// Subsequence matching over the whole candidate, words and all.
    private static func spanning(_ candidate: String, query: String) -> Result? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else {
            return Result(score: 0, matchedOffsets: [])
        }

        let hay = Array(candidate.lowercased())
        guard needle.count <= hay.count else { return nil }

        var total = 0
        var needleIndex = 0
        var previousMatch: Int? = nil
        var offsets: [Int] = []
        offsets.reserveCapacity(needle.count)

        for (i, ch) in hay.enumerated() {
            guard needleIndex < needle.count, ch == needle[needleIndex] else {
                continue
            }

            total += matchScore
            if let previous = previousMatch, previous == i - 1 {
                total += contiguousBonus
            }
            if isWordStart(hay, i) {
                total += wordStartBonus
            }
            if previousMatch == nil {
                total -= min(i * leadingPenalty, maxLeadingPenalty)
            }

            offsets.append(i)
            previousMatch = i
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        return Result(score: total, matchedOffsets: offsets)
    }

    /// Just the score, for callers that rank but do not highlight.
    public static func score(
        _ candidate: String, query: String, scope: Scope = .subsequence
    ) -> Int? {
        result(candidate, query: query, scope: scope)?.score
    }

    /// Whether the query matches at all. An empty query matches everything.
    public static func matches(
        _ candidate: String, query: String, scope: Scope = .subsequence
    ) -> Bool {
        result(candidate, query: query, scope: scope) != nil
    }

    /// A character begins a word when it opens the string or follows a
    /// separator. Space-separated chords ("a i") count each key as a word start,
    /// which is what lets "ai" rank as a real hit rather than noise; newlines and
    /// tabs count so the first word of each line of a body does too.
    private static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = chars[i - 1]
        return previous == " " || previous == "-" || previous == "_"
            || previous == "/" || previous == "\n" || previous == "\t"
    }
}
