import Foundation

/// Reading a query that is changing the root rather than filtering it.
///
/// One field does both jobs, distinguished by how the query starts: a leading
/// `/` or `~` is a path being typed, anything else is a filter. That is the
/// shell's convention and needs no explaining to anyone who has used one — and
/// it keeps the common case, filtering, free of a mode to be in.
public enum FilePickerRootInput {

    /// Whether this query is a path being typed rather than a filter.
    public static func isRootChange(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// The absolute path a root-change query names, with `~` expanded.
    ///
    /// Nil when the query is not a root change, so a caller can use this as the
    /// test rather than asking twice.
    public static func expandedPath(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isRootChange(trimmed) else { return nil }
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst(1))
        }
        return trimmed
    }

    /// The directory whose children a partly-typed path is choosing between.
    ///
    /// `~/pro` is choosing among the children of `~`; `~/projects/` is choosing
    /// among the children of `~/projects`. The trailing separator is the whole
    /// distinction, and it cannot be left to `deletingLastPathComponent`, which
    /// strips a trailing slash *before* removing a component and so answers
    /// `~` for both.
    public static func candidateParent(of query: String) -> String? {
        guard let typed = expandedPath(query) else { return nil }
        guard typed.hasSuffix("/") else {
            return (typed as NSString).deletingLastPathComponent
        }
        return typed == "/" ? "/" : String(typed.dropLast())
    }

    /// Extend a partly-typed path to the longest prefix every candidate shares,
    /// and close a finished segment with the separator.
    ///
    /// The shell's Tab, and the reason it is worth having rather than making
    /// someone type a path in full: one press either finishes the segment or
    /// tells them — by not moving — that they have to choose.
    ///
    /// - Parameters:
    ///   - query: what has been typed, as a root-change query.
    ///   - directories: absolute paths of the directories that could continue
    ///     it. Supplied rather than listed here, because reading a directory is
    ///     the host's business and this stays testable without one.
    /// - Returns: the extended query, or nil when there is nothing to add —
    ///   no candidates, or they already disagree at the next character.
    public static func completion(
        for query: String,
        directories: [String]
    ) -> String? {
        guard let typed = expandedPath(query) else { return nil }

        let matching = directories.filter { $0.hasPrefix(typed) }
        guard !matching.isEmpty else { return nil }

        var extended = longestCommonPrefix(matching)

        // The separator is what says "keep going", and having to type it at
        // every level is the friction this exists to remove. Withheld unless
        // the segment is genuinely settled: one candidate, or a name already
        // typed in full while longer siblings exist. **Not** merely because the
        // shared prefix happens to name a directory — completing `/work/pro` to
        // `/work/project/` when `/work/projections` is also there would commit
        // a choice the reader had not made and put the sibling out of reach.
        let settled =
            matching.count == 1 || (extended == typed && matching.contains(typed))
        if settled, !extended.hasSuffix("/") { extended += "/" }

        guard extended.count > typed.count else { return nil }

        // Re-abbreviated, so a reader who typed `~` keeps seeing `~`. Replacing
        // it with their home path would be correct and would read as the field
        // rewriting what they typed.
        let home = NSHomeDirectory()
        if query.trimmingCharacters(in: .whitespaces).hasPrefix("~"),
           extended.hasPrefix(home)
        {
            return "~" + extended.dropFirst(home.count)
        }
        return extended
    }

    /// The longest prefix shared by every string, compared by character.
    static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            var candidate = ""
            for (a, b) in zip(prefix, string) {
                if a != b { break }
                candidate.append(a)
            }
            prefix = candidate
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
