import Foundation

/// Filtering the ⌘/ cheat sheet against its search field.
///
/// Pure and Foundation-only, so a test can assert what the sheet decides. The
/// rule used to live inline in the view, and that is why nobody noticed it
/// reading a whole row as one gap-anywhere subsequence: nothing could reach it
/// to check.
public enum CheatSheetSearch {

    /// Everything a row puts on screen, all of it searchable.
    ///
    /// The section title and the condition are in here on purpose: typing
    /// a section's name should turn up that part of the sheet, and the header
    /// is the only place that word appears. They were briefly excluded because
    /// including them made short queries match almost the whole catalog — but
    /// that was the subsequence reading's fault, not theirs. Read as terms, a
    /// long condition can only answer to words it actually contains.
    public struct Candidate: Equatable {
        public let label: String
        public let keys: String
        public let section: String
        public let condition: String
        /// Other words for the same thing, and the spelled-out names of the
        /// keystroke's glyphs. Matched like the rest; drawn nowhere, so a row
        /// kept for one of these shows no highlight — the section and the label
        /// are what explain it.
        public let aliases: String

        public init(
            label: String,
            keys: String,
            section: String,
            condition: String,
            aliases: String = ""
        ) {
            self.label = label
            self.keys = keys
            self.section = section
            self.condition = condition
            self.aliases = aliases
        }
    }

    /// Where a query landed, so a row can show why it matched. Per field,
    /// because each is rendered separately; the section is a shared header and
    /// has nowhere to put a highlight.
    public struct Hit: Equatable {
        public let labelOffsets: [Int]
        public let keysOffsets: [Int]
        public let conditionOffsets: [Int]

        /// All three default, so `Hit()` is the "matched, nothing to draw"
        /// value an empty query and a section-only match both produce.
        public init(
            labelOffsets: [Int] = [],
            keysOffsets: [Int] = [],
            conditionOffsets: [Int] = []
        ) {
            self.labelOffsets = labelOffsets
            self.keysOffsets = keysOffsets
            self.conditionOffsets = conditionOffsets
        }
    }

    /// Match every candidate, index-aligned with nil where one is filtered out.
    /// An empty query matches everything and highlights nothing.
    ///
    /// One rule for every field: a query matches inside a word, and a space is
    /// the only way to cross one — it stands in for `.+`, so "th e" spans where
    /// "the" cannot. A row matches when any one of its fields does.
    ///
    /// Deliberately no second, looser pass. An earlier version fell back to
    /// gap-anywhere subsequence matching when nothing matched strictly, to keep
    /// initials like "mti" finding "Move to Icebox". It cost more than it bought:
    /// "scrat" matched "Leave input mode (discards the draft)" through five
    /// characters scattered over three words, and a search that answers a typo
    /// with a wrong row is worse than one that answers nothing. Initials are not
    /// worth a rule the reader cannot predict.
    public static func hits(
        _ candidates: [Candidate], query: String
    ) -> [Hit?] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates.map { _ in Hit() } }
        // Resolved once for the whole catalogue rather than once per field per
        // row — five fields over a hundred-odd rows is the same split and
        // lowercase several hundred times for one keystroke.
        let prepared = FuzzyMatch.PreparedQuery(trimmed, scope: .terms)
        return candidates.map { hit($0, prepared: prepared) }
    }

    private static func hit(
        _ c: Candidate, prepared: FuzzyMatch.PreparedQuery
    ) -> Hit? {
        func offsets(_ field: String) -> [Int]? {
            FuzzyMatch.result(field, prepared: prepared)?.matchedOffsets
        }
        let label = offsets(c.label)
        let keys = offsets(c.keys)
        let condition = offsets(c.condition)
        // Neither of these is highlighted: the section is drawn once above a
        // run of rows, and the aliases are not drawn at all.
        let section = offsets(c.section)
        let aliases = offsets(c.aliases)
        guard label != nil || keys != nil || condition != nil
                || section != nil || aliases != nil
        else { return nil }
        return Hit(
            labelOffsets: label ?? [],
            keysOffsets: keys ?? [],
            conditionOffsets: condition ?? [])
    }
}
