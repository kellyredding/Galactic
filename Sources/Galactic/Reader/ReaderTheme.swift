import Foundation

/// The colours a reader document is drawn in.
///
/// Eight roles, and every reader used to declare the ones it needed as
/// literals at the top of its own HTML builder. Seven copies, and they did
/// agree — the same hex for the same role in all of them — which is what made
/// the arrangement survive: nothing ever looked wrong, so nothing prompted
/// anyone to name it. The cost was only visible when changing one, because
/// there was no list of the other six places to change.
///
/// The overlap ran further than the readers. `annotationCSSVars` carried the
/// same values again for four of these roles, as CSS custom properties, and it
/// is now interpolated from here rather than holding its own copy.
///
/// ### Extending it
///
/// A reader with a colour nothing else has — a diff's hover lift, a
/// transcript's tool badges — keeps it locally. This is the palette shared
/// across readers, not every colour any reader uses, and pulling one-offs in
/// would make it a dumping ground rather than a vocabulary.
public struct ReaderTheme: Equatable, Sendable {
    public let isDark: Bool

    /// The page itself.
    public let background: String
    /// Body text.
    public let foreground: String
    /// De-emphasised text — captions, metadata, blockquotes.
    public let mutedForeground: String
    /// Line numbers in a gutter. Dimmer than `mutedForeground` in dark and
    /// brighter in light, because a gutter sits against `gutter` rather than
    /// against the page.
    public let lineNumber: String
    /// The strip a line-number column sits in. Recedes from the page.
    public let gutter: String
    /// Rules and outlines.
    public let border: String
    /// A surface that sits above the page — table headers, card backgrounds,
    /// the alternating row in a stripe.
    public let raisedSurface: String
    /// A surface that sits below it — inset code blocks. Identical to
    /// `background` in dark, where sinking further would reach black.
    public let sunkenSurface: String
    /// Links and other interactive text.
    public let accent: String

    public init(
        isDark: Bool,
        background: String,
        foreground: String,
        mutedForeground: String,
        lineNumber: String,
        gutter: String,
        border: String,
        raisedSurface: String,
        sunkenSurface: String,
        accent: String
    ) {
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.mutedForeground = mutedForeground
        self.lineNumber = lineNumber
        self.gutter = gutter
        self.border = border
        self.raisedSurface = raisedSurface
        self.sunkenSurface = sunkenSurface
        self.accent = accent
    }

    /// The palette the readers already shared, named.
    public static func standard(isDark: Bool) -> ReaderTheme {
        isDark
            ? ReaderTheme(
                isDark: true,
                background: "#0d1117",
                foreground: "#e6edf3",
                mutedForeground: "#8b949e",
                lineNumber: "#6e7681",
                gutter: "#010409",
                border: "#30363d",
                raisedSurface: "#161b22",
                sunkenSurface: "#0d1117",
                accent: "#58a6ff"
            )
            : ReaderTheme(
                isDark: false,
                background: "#ffffff",
                foreground: "#1f2328",
                mutedForeground: "#656d76",
                lineNumber: "#8b949e",
                gutter: "#f6f8fa",
                border: "#d0d7de",
                raisedSurface: "#f6f8fa",
                sunkenSurface: "#f6f8fa",
                accent: "#0969da"
            )
    }
}
