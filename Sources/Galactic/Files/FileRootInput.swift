import Foundation

/// Reading a query that is changing the root rather than filtering it.
///
/// One field does both jobs, distinguished by how the query starts: a leading
/// `/` or `~` is a path being typed, anything else is a filter. That is the
/// shell's convention and needs no explaining to anyone who has used one — and
/// it keeps the common case, filtering, free of a mode to be in.
public enum FileRootInput {

    /// Whether this query is a path being typed rather than a filter.
    ///
    /// - Parameter route: where the picker currently says it is, which is what
    ///   a relative path is relative to. Without one there is nothing for `.`
    ///   or `..` to mean, so they stay filters.
    public static func isRootChange(_ query: String, route: String? = nil)
        -> Bool
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return true }
        guard route != nil else { return false }
        return isRelative(trimmed)
    }

    /// Whether the first segment is exactly `.` or `..`.
    ///
    /// **Tested whole, and that is the entire subtlety.** A leading dot cannot
    /// simply mean "a path": `.env`, `.gitignore` and `.zshrc` are things a
    /// reader types to *filter*, and there are more dotfiles in a checkout than
    /// there are reasons to type `..`. Getting this wrong turns a common filter
    /// into a failed directory lookup, which reads as the file not existing.
    static func isRelative(_ trimmed: String) -> Bool {
        let first =
            trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return first == "." || first == ".."
    }

    /// The absolute path a root-change query names, with `~` expanded and any
    /// leading `.` or `..` resolved against the route.
    ///
    /// Nil when the query is not a root change, so a caller can use this as the
    /// test rather than asking twice.
    public static func expandedPath(_ query: String, route: String? = nil)
        -> String?
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isRootChange(trimmed, route: route) else { return nil }
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst(1))
        }
        if trimmed.hasPrefix("/") { return trimmed }
        guard let route else { return nil }
        return resolve(trimmed, against: route)
    }

    /// Walk off the leading `.` and `..` segments, then hang the rest on what
    /// is left.
    ///
    /// Only the *leading* run is resolved. An interior `..` is left in place
    /// for the filesystem to settle, because the alternative — standardising
    /// the whole path — also rewrites symlinked prefixes, and every caller here
    /// matches the result against names read from a directory. A resolved
    /// spelling silently matches none of them.
    private static func resolve(_ typed: String, against route: String)
        -> String?
    {
        let parts = split(typed, against: route)
        let rest = parts.rest.joined(separator: "/")
        var result = parts.base
        if !rest.isEmpty {
            result =
                parts.base.hasSuffix("/")
                ? parts.base + rest : parts.base + "/" + rest
        }
        if parts.trailing, !result.hasSuffix("/") { result += "/" }
        return result
    }

    /// A relative query in three pieces: the `.`/`..` run as the reader typed
    /// it, the directory that run resolves to, and what follows.
    private static func split(_ typed: String, against route: String)
        -> (lead: [String], base: String, rest: [String], trailing: Bool)
    {
        var segments =
            typed.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        // A trailing separator leaves an empty final segment. It carries the
        // "show me what is inside" meaning the folder list reads, so it is
        // remembered rather than resolved away.
        let trailing = segments.count > 1 && segments.last == ""
        if trailing { segments.removeLast() }

        var base = route
        var index = 0
        while index < segments.count {
            if segments[index] == "." {
                index += 1
            } else if segments[index] == ".." {
                base = (base as NSString).deletingLastPathComponent
                index += 1
            } else {
                break
            }
        }
        return (
            Array(segments[..<index]), base, Array(segments[index...]), trailing
        )
    }

    /// The directory whose children a partly-typed path is choosing between.
    ///
    /// `~/pro` is choosing among the children of `~`; `~/projects/` is choosing
    /// among the children of `~/projects`. The trailing separator is the whole
    /// distinction, and it cannot be left to `deletingLastPathComponent`, which
    /// strips a trailing slash *before* removing a component and so answers
    /// `~` for both.
    public static func candidateParent(of query: String, route: String? = nil)
        -> String?
    {
        guard let typed = expandedPath(query, route: route) else { return nil }
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
        directories: [String],
        route: String? = nil
    ) -> String? {
        guard let typed = expandedPath(query, route: route) else { return nil }

        let matching = directories.filter { continues($0, typed: typed) }
        guard !matching.isEmpty else { return nil }

        // **The shared prefix is measured under the same case rule that chose
        // the candidates.** Measured case-sensitively while they were chosen
        // leniently, `kaj` against a folder holding both `kajabi-dev` and
        // `Kajabi-Dash-App-iOS` shares nothing at all — `K` and `k` differ at
        // the first character — so Tab did nothing in a directory where six
        // characters were obviously common.
        //
        // Which spelling those characters are taken from is a separate
        // question, and the answer is a candidate that matches what the reader
        // typed when one exists: their own letters are left alone, and only the
        // part they have not typed yet is spelled by the disk. Finder order
        // decides between equals, because enumeration order is not stable and a
        // completion that varies between presses is worse than one that is
        // occasionally the wrong sibling's capital.
        let ordered = matching.sorted(by: FileFolderList.precedes)
        let source = ordered.first { $0.hasPrefix(typed) } ?? ordered[0]
        let sensitive = (typed as NSString).lastPathComponent
            .contains { $0.isUppercase }
        var extended = String(
            source.prefix(
                sharedPrefixLength(of: ordered, caseSensitive: sensitive)
            )
        )

        // The separator is what says "keep going", and having to type it at
        // every level is the friction this exists to remove. Withheld unless
        // the segment is genuinely settled: one candidate, or a name already
        // typed in full while longer siblings exist. **Not** merely because the
        // shared prefix happens to name a directory — completing `/work/pro` to
        // `/work/project/` when `/work/projections` is also there would commit
        // a choice the reader had not made and put the sibling out of reach.
        let settled =
            matching.count == 1
            || (extended.count == typed.count
                && matching.contains { begins($0, with: typed) && $0.count == typed.count })
        if settled, !extended.hasSuffix("/") { extended += "/" }

        guard extended.count > typed.count else { return nil }

        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Re-abbreviated, so a reader who typed `~` keeps seeing `~`. Replacing
        // it with their home path would be correct and would read as the field
        // rewriting what they typed.
        let home = NSHomeDirectory()
        if trimmed.hasPrefix("~"), extended.hasPrefix(home) {
            return "~" + extended.dropFirst(home.count)
        }

        // The same courtesy for a relative path, for the same reason: `../Doc`
        // completes to `../Documents/` rather than to the absolute directory
        // that names. The reader said where they were going relative to here,
        // and answering with an absolute path discards the part they chose to
        // say — and makes the next `..` mean something different.
        if let route, isRelative(trimmed) {
            let parts = split(trimmed, against: route)
            if extended.hasPrefix(parts.base) {
                let tail = extended.dropFirst(parts.base.count)
                let lead = parts.lead.joined(separator: "/")
                return lead + (tail.hasPrefix("/") ? String(tail) : "/" + tail)
            }
        }
        return extended
    }

    /// Whether an absolute path is one of the things a partly-typed path could
    /// still become.
    ///
    /// The parent portion of both sides is identical by construction — the
    /// caller derived the parent from this same typed text, and spelled every
    /// child against it — so the only part that can disagree in case is the
    /// final segment, and that is the only part the case rule is applied to.
    ///
    /// **Applying it to the whole path instead would make every path under a
    /// home directory case-sensitive**, because `/Users` carries a capital `U`
    /// that the reader never typed. That is the trap here: the rule reads as
    /// though it should be asked of the whole string, and asked that way it is
    /// always answered the same.
    static func continues(_ candidate: String, typed: String) -> Bool {
        // A finished segment has no partial to fold, and the prefix is exact.
        guard !typed.hasSuffix("/") else { return candidate.hasPrefix(typed) }

        let parent = (typed as NSString).deletingLastPathComponent
        guard (candidate as NSString).deletingLastPathComponent == parent else {
            return false
        }
        return begins(
            (candidate as NSString).lastPathComponent,
            with: (typed as NSString).lastPathComponent
        )
    }

    /// Smart case, which is the matcher's rule rather than a second one
    /// invented here: an uppercase letter anywhere in what was typed asks for
    /// an exact answer, and an all-lowercase segment is answered leniently. So
    /// `~/lib` reaches `Library` and `~/Lib` still does, while `~/LIB` does
    /// not — the same bargain `FileMatcher.PreparedQuery` strikes.
    static func begins(_ name: String, with typed: String) -> Bool {
        guard !typed.isEmpty else { return true }
        if typed.contains(where: { $0.isUppercase }) {
            return name.hasPrefix(typed)
        }
        return name.lowercased().hasPrefix(typed.lowercased())
    }

    /// The longest prefix shared by every string, compared by character.
    static func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        return String(
            first.prefix(sharedPrefixLength(of: strings, caseSensitive: true))
        )
    }

    /// How many leading characters every string agrees on.
    ///
    /// A length rather than a prefix, because when case is being folded there is
    /// no single right *spelling* of those characters — the caller decides whose
    /// to use, and only it knows what the reader typed.
    static func sharedPrefixLength(
        of strings: [String], caseSensitive: Bool
    ) -> Int {
        guard let first = strings.first else { return 0 }
        var length = first.count
        for string in strings.dropFirst() {
            var shared = 0
            for (a, b) in zip(first, string) {
                if caseSensitive ? a != b : a.lowercased() != b.lowercased() {
                    break
                }
                shared += 1
            }
            length = min(length, shared)
            if length == 0 { break }
        }
        return length
    }
}
