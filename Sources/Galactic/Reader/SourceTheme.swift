import Foundation

/// The colours a source document is drawn in, and the stylesheet that colours
/// its tokens.
///
/// Deliberately narrower than `ReaderTheme`, which dresses every reader. A
/// custom theme moves the code surface and leaves markdown, tables, images,
/// transcripts and the diff exactly where they were, so the fields here are
/// the ones a source document actually reads and no others: there is no
/// `accent` because code has no links, and no `border` because the only rule a
/// source document draws is the gutter's.
public struct SourceTheme: Sendable, Equatable {
    /// The highlight.js stylesheet, spliced into the document.
    public let highlightCSS: String
    /// The page.
    public let background: String
    /// Body text, and code text in a file whose language is unknown.
    public let foreground: String
    /// The strip the line numbers sit in.
    public let gutter: String
    /// Line-number text.
    public let lineNumber: String
    /// The rule dividing the gutter from the code.
    public let gutterBorder: String

    public init(
        highlightCSS: String,
        background: String,
        foreground: String,
        gutter: String,
        lineNumber: String,
        gutterBorder: String
    ) {
        self.highlightCSS = highlightCSS
        self.background = background
        self.foreground = foreground
        self.gutter = gutter
        self.lineNumber = lineNumber
        self.gutterBorder = gutterBorder
    }
}

extension SourceTheme {
    /// The theme a source document is built with, unless a host says otherwise.
    ///
    /// Discards nothing and answers stock until a host replaces it. Written
    /// once at launch, before anything here can run, and read on the main
    /// thread thereafter — the same lifecycle and the same reasoning as
    /// `GalacticLog.sink`, whose comment is the longer form of this one.
    ///
    /// A closure rather than a stored pair because a host reads its theme from
    /// disk: resolving per call is what lets an edited stylesheet appear
    /// without restarting the app.
    ///
    /// `isDark` stays an argument rather than being folded into the value,
    /// because a reader's appearance is a property of the document being built
    /// and a host can render one of each at the same time — the contract
    /// `ReaderAssets` already states.
    nonisolated(unsafe) public static var provider:
        (_ isDark: Bool) -> SourceTheme = { stock(isDark: $0) }

    /// The theme for an appearance, asking the host first.
    public static func active(isDark: Bool) -> SourceTheme {
        provider(isDark)
    }

    /// Today's rendering, named.
    ///
    /// Built from the values the readers already use rather than derived from
    /// the stock stylesheets, so an uninstalled theme is not merely close to
    /// the current output — it is the current output, byte for byte. That is
    /// what lets derivation elsewhere aim at looking right rather than at
    /// reproducing a known answer.
    public static func stock(isDark: Bool) -> SourceTheme {
        let palette = ReaderTheme.standard(isDark: isDark)
        return SourceTheme(
            highlightCSS: ReaderAssets.highlightThemeCSS(isDark: isDark),
            background: palette.background,
            foreground: palette.foreground,
            gutter: palette.gutter,
            lineNumber: palette.lineNumber,
            // Not from the palette: `ReaderTheme.border` is a heavier rule used
            // for card outlines, and the gutter's divider has always been its
            // own lighter value.
            gutterBorder: isDark ? "#21262d" : "#d0d7de"
        )
    }
}
