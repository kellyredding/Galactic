import Foundation

/// What the picker offers, and in what order.
///
/// Separate from the presenter and the view so it can be tested without either.
/// The ranking is the part a reader feels most directly — a picker that puts the
/// right file second is worse than one that takes an extra keystroke.
public enum FilePickerRanking {

    /// How many rows a reader is offered at once.
    ///
    /// Ranked results are capped because past the first screenful the ordering
    /// stops being read; the empty list is capped because it is a suggestion,
    /// not an archive.
    public static let resultLimit = 100
    public static let emptyListLimit = 20

    /// Rank an index against a query.
    ///
    /// Subsequence rather than contiguous terms, which is the opposite of the
    /// cheat sheet's choice and right here for a different corpus: a reader
    /// types `usermodel` for `user_model.rb`, and contiguity would refuse it
    /// over the underscore. `FuzzyMatch` already treats `/` as a word start, so
    /// a path segment beginning with a typed character is scored above one
    /// merely containing it.
    ///
    /// **Whitespace in the query is a gap, not a character to find.** Nobody
    /// types a whole path; they type remembered fragments in the order they
    /// remember them — `projects kelly readme` — and the space between them
    /// means "then, somewhere later". Since a subsequence match already allows
    /// a gap between every character, dropping the spaces *is* that rule rather
    /// than an approximation of it.
    ///
    /// Kept literal, a space was worse than useless: it went into the
    /// necessary-condition set below, no path contained one, and every single
    /// candidate was rejected before it was ever scored. A query with a space
    /// answered "no file matches" over a tree full of matches.
    ///
    /// This also does the right thing by the filenames that *do* contain
    /// spaces — `Desktop/AI prompts.txt` still answers to `ai prompts`, because
    /// the space in the path is simply one of the gaps the subsequence skips.
    public static func matches(
        _ items: [FileTreeIndex.Item],
        query: String,
        limit: Int = resultLimit
    ) -> [FilePickerItem] {
        let condensed = query.filter { !$0.isWhitespace }
        guard !condensed.isEmpty else { return [] }

        let prepared = FuzzyMatch.PreparedQuery(condensed, scope: .subsequence)
        // A necessary condition, checked before anything is scored: a
        // subsequence match needs every query character to appear somewhere.
        // Rejecting on that is a set lookup against a string lowercased once at
        // index time, where scoring is an allocation and a walk — and over tens
        // of thousands of files the difference is whether the picker keeps up
        // with typing.
        let required = Set(condensed.lowercased())

        var scored: [(item: FileTreeIndex.Item, result: FuzzyMatch.Result)] = []
        for item in items {
            let candidate = item.lowercasedRelativePath
            guard required.allSatisfy({ candidate.contains($0) }) else {
                continue
            }
            guard
                let result = FuzzyMatch.result(
                    item.relativePath, prepared: prepared
                )
            else { continue }
            scored.append((item, result))
        }

        return
            scored
            .sorted {
                // Score first; then the shorter path, because a match in a
                // short path is more often the one meant; then alphabetically,
                // so the order does not shuffle between identical queries.
                if $0.result.score != $1.result.score {
                    return $0.result.score > $1.result.score
                }
                if $0.item.relativePath.count != $1.item.relativePath.count {
                    return $0.item.relativePath.count
                        < $1.item.relativePath.count
                }
                return $0.item.relativePath < $1.item.relativePath
            }
            .prefix(limit)
            .map {
                FilePickerItem(
                    url: $0.item.url,
                    relativePath: $0.item.relativePath,
                    matchedOffsets: $0.result.matchedOffsets,
                    source: .matched
                )
            }
    }

    /// What an empty query offers: files closed in this set, then files opened
    /// earlier and left open.
    ///
    /// Closed first because closing is a deliberate act and reopening is the
    /// commonest reason to come here at all. Recents behind them so the list is
    /// not empty for a reader who has closed nothing yet.
    ///
    /// A file appearing in both is listed once, as closed — the stronger signal.
    public static func emptyQueryList(
        closed: [ClosedTabStack.Entry],
        recent: [URL],
        root: URL,
        limit: Int = emptyListLimit
    ) -> [FilePickerItem] {
        var seen = Set<String>()
        var rows: [FilePickerItem] = []

        func offer(_ url: URL, _ source: FilePickerItem.Source) {
            guard seen.insert(url.path).inserted else { return }
            rows.append(
                FilePickerItem(
                    url: url,
                    relativePath: FileTabLabel.relativeOrAbbreviated(
                        url, root: root
                    ),
                    source: source
                )
            )
        }

        for entry in closed { offer(entry.url, .closed) }
        for url in recent { offer(url, .recent) }
        return Array(rows.prefix(max(0, limit)))
    }
}
