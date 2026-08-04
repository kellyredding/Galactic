import Foundation

/// One line of a cheat sheet, already resolved.
///
/// Everything here is a decision the host has finished making: which keystroke
/// this row is for, how to spell it, what condition governs it, and whether
/// that condition holds right now. Nothing in this package knows what a
/// binding, a surface, or an availability rule is — a host resolves all three
/// against whatever it keeps them in and hands over the answers.
///
/// That is the whole shape of the seam, and it is deliberate. Making the
/// package generic over a host's availability type was the alternative, and it
/// breaks in three places at once: the host's availability is `Equatable`
/// against its own cases, the condition text is derived from those cases, and
/// the empty context a closed sheet reports cannot be spelled generically.
public struct CheatSheetRow: Identifiable, Equatable {
    /// Unique across the **whole sheet**, not within a section.
    ///
    /// Every row in every section lands in one container, so a repeated id is
    /// what puts rows under the wrong header and leaves holes where the list
    /// believed it had already built something. A positional index alone is not
    /// enough: it restarts at zero in each section. Composing the section's own
    /// id into the row's is the cheapest way to be right — and it is the host
    /// that composes it, because the host is the only side that knows what
    /// two rows rendering identically actually are.
    public let id: String

    /// The keystroke as a reader sees it — "⇧⌘⌫", "⌥⌘H", "esc".
    ///
    /// One keystroke, not one command. A rebindable action can carry several,
    /// and stacking them into one cell blows out a column every other row is
    /// aligned to, so a host with three keystrokes for one action supplies
    /// three rows.
    public let keys: String

    /// What the keystroke does.
    public let label: String

    /// When it is usable, in words. Empty when there is no condition worth
    /// stating, and empty is drawn as nothing rather than as a blank column.
    public let condition: String

    /// Whether the condition holds under the snapshot the sheet opened with.
    ///
    /// False dims the row; it never hides it. The sheet is a reference first,
    /// so its job is to show what exists and let the dimming say what is live.
    public let isActive: Bool

    /// Other words for the same thing: searched, drawn nowhere.
    ///
    /// A row kept for one of these shows no highlight, which is honest — the
    /// section and the label are what explain it. The view appends this row's
    /// own glyphs spelled out (see `CheatSheetGlyphs`) before searching, so a
    /// host only supplies synonyms it authored, and a host with none says
    /// nothing.
    public let aliases: String

    public init(
        id: String,
        keys: String,
        label: String,
        condition: String,
        isActive: Bool,
        aliases: String = ""
    ) {
        self.id = id
        self.keys = keys
        self.label = label
        self.condition = condition
        self.isActive = isActive
        self.aliases = aliases
    }
}

/// A run of rows under one heading.
///
/// Sections are drawn in the order the host supplies them, and rows in the
/// order the host supplies them inside each — never sorted by match score. A
/// host groups related chords together on purpose, and reshuffling them by
/// match quality scatters that grouping the moment a query touches it.
/// Highlighting is what tells the reader why a row is in the list, which is the
/// job ranking would otherwise be doing.
public struct CheatSheetSection: Identifiable, Equatable {
    /// Unique across the sheet.
    ///
    /// A `String` rather than a host's own type because it has to survive the
    /// package boundary as a value, and a raw value, a `UUID`, or an enum's
    /// `rawValue` can all become one.
    public let id: String

    /// The heading, as drawn — and searched, so typing a section's name turns
    /// up that part of the sheet. The header is usually the only place that
    /// word appears at all.
    public let title: String

    public let rows: [CheatSheetRow]

    /// Open the sheet scrolled to this section. Read once, on the list's first
    /// appear.
    ///
    /// A flag on the section rather than a second closure on the presenter, and
    /// the reason is the one this whole design turns on: a separate provider
    /// would let a host take two independent snapshots — one for the rows, one
    /// for where to open — with nothing forcing them to agree. Travelling
    /// inside the value that already crossed the seam, it is computed from the
    /// same snapshot by construction.
    ///
    /// Safe in both directions: none marked opens at the top, several marked
    /// means the first wins.
    public let isOpening: Bool

    public init(
        id: String,
        title: String,
        rows: [CheatSheetRow],
        isOpening: Bool = false
    ) {
        self.id = id
        self.title = title
        self.rows = rows
        self.isOpening = isOpening
    }
}
