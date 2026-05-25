import Foundation

/// Per-cell visual style — the triple of fg color, bg color,
/// and SGR-style flags. Pulled out as its own struct so
/// renderers can batch consecutive cells with identical style
/// into a single span (the most expensive output per cell is
/// the style declaration, not the character itself).
///
/// `Equatable` synthesized — renderers compare adjacent cells'
/// styles to detect span boundaries.
public struct ScrollbackCellStyle: Equatable {
    public let foreground: ScrollbackColor
    public let background: ScrollbackColor
    public let attributes: ScrollbackAttributes

    public init(
        foreground: ScrollbackColor,
        background: ScrollbackColor,
        attributes: ScrollbackAttributes
    ) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

/// One cell in a scrollback snapshot. Engine-agnostic — the
/// backend's iteration code converts its native cell type
/// (e.g. SwiftTerm's `CharData`) into this representation
/// during `ScrollbackSnapshot.enumerateCells(...)`.
///
/// The character is pre-resolved as a `String` so renderers
/// don't need to know about backend-internal codepoint vs
/// extended-grapheme-cluster encoding. Null cells (terminal
/// emulator value 0) are resolved to a single space, matching
/// what most renderers want to emit.
public struct ScrollbackCell {
    /// The displayable character for this cell. Always a valid
    /// string — null cells are resolved to `" "` by the backend.
    public let character: String

    /// Column span: 0 for the continuation half of a wide
    /// character (CJK / some emoji), 1 for a normal cell, 2 for
    /// the leading half of a wide character. Renderers
    /// typically skip continuation cells (width=0) because the
    /// leading cell at column N-1 already spans columns N-1 and
    /// N.
    public let columnWidth: Int

    /// Per-cell visual style. Renderers batch cells with equal
    /// style into single output spans.
    public let style: ScrollbackCellStyle

    public init(
        character: String,
        columnWidth: Int,
        style: ScrollbackCellStyle
    ) {
        self.character = character
        self.columnWidth = columnWidth
        self.style = style
    }
}
