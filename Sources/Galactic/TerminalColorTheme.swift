import AppKit

/// 16-bit RGB color used for the 16-entry ANSI palette installed on the
/// terminal surface. Galaxy-owned so the `TerminalBackend` protocol can
/// express the palette operation without naming SwiftTerm types.
///
/// Values are 0…65535 to preserve the precision the underlying SwiftTerm
/// `Color` type uses; backend implementations convert at the boundary.
public struct TerminalPaletteColor: Equatable, Hashable {
    public let red: UInt16
    public let green: UInt16
    public let blue: UInt16

    public init(red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A terminal color theme defining foreground, background, and the 16
/// standard ANSI colors. Designed for JSON serialization so user-defined
/// themes can be stored in settings in the future.
public struct TerminalColorTheme: Codable, Identifiable {
    public let id: String          // e.g. "galaxy-default"
    public let name: String        // e.g. "Galaxy Default"
    public let foreground: String  // Hex "#RRGGBB"
    public let background: String  // Hex "#RRGGBB"
    public let ansiColors: [String] // 16 hex values, indices 0-7 normal, 8-15 bright
    public let boldForeground: String?  // Optional explicit bold text color; nil = use ANSI 15

    public init(
        id: String,
        name: String,
        foreground: String,
        background: String,
        ansiColors: [String],
        boldForeground: String?
    ) {
        self.id = id
        self.name = name
        self.foreground = foreground
        self.background = background
        self.ansiColors = ansiColors
        self.boldForeground = boldForeground
    }

    // MARK: - Computed NSColor Properties

    public var foregroundColor: NSColor { Self.nsColor(from: foreground) }
    public var backgroundColorValue: NSColor { Self.nsColor(from: background) }

    /// Perceived brightness of the background (0 = black, 1 = white).
    /// Uses the ITU-R BT.601 luma formula: 0.299R + 0.587G + 0.114B.
    public var backgroundLuminance: CGFloat {
        let c = backgroundColorValue.usingColorSpace(.sRGB) ?? backgroundColorValue
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// Bold default foreground: use explicit bold color if provided,
    /// otherwise fall back to the theme's bright white (ANSI index 15).
    public var boldForegroundColor: NSColor {
        if let explicit = boldForeground {
            return Self.nsColor(from: explicit)
        }
        return Self.nsColor(from: ansiColors[15])
    }

    /// Convert ANSI hex colors to a backend-agnostic 16-color palette.
    /// Each backend converts to its own palette type at the boundary.
    public var terminalPalette: [TerminalPaletteColor] {
        ansiColors.map { hex in
            let ns = Self.nsColor(from: hex)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            return TerminalPaletteColor(
                red: UInt16(r * 65535),
                green: UInt16(g * 65535),
                blue: UInt16(b * 65535)
            )
        }
    }

    // MARK: - Hex Parsing

    public static func nsColor(from hex: String) -> NSColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let value = UInt32(h, radix: 16) else {
            return NSColor.white
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Built-in Themes

extension TerminalColorTheme {
    /// Built-in themes. Galaxy Default is pinned at the top as the
    /// app's bundled default; the rest are alphabetized by name.
    public static let builtIn: [TerminalColorTheme] = [
        .galaxyDefault,
        .alacrittyDefault,
        .catppuccinMocha,
        .dracula,
        .ghosttyDefault,
        .gruvboxDark,
        .nord,
        .oneHalfDark,
        .oneDark,
        .solarizedDark,
        .solarizedLight,
        .swiftTermDark,
        .swiftTermLight,
    ]

    /// Find a theme by ID, falling back to Galaxy Default
    public static func theme(named id: String) -> TerminalColorTheme {
        builtIn.first { $0.id == id } ?? .galaxyDefault
    }

    // MARK: Galaxy Default
    // Galaxy's bundled default theme. Originated as a pixel-sample
    // of macOS Terminal.app's default palette (macOS 15) and now
    // diverges in the blue slots — ANSI 4 (#569CD6, VS Code Dark+
    // base blue) and ANSI 12 (#82B8FF, a more-saturated bright
    // blue) — for better legibility on a black background. Bold
    // default-fg renders as pure white.
    static let galaxyDefault = TerminalColorTheme(
        id: "galaxy-default",
        name: "Galaxy Default",
        foreground: "#EBEBEB",
        background: "#000000",
        ansiColors: [
            "#000000", "#8C1B10", "#4AA32E", "#99992F",
            "#569CD6", "#A320AC", "#4AA3B0", "#BFBFBF",
            "#666666", "#D32D1F", "#62D640", "#E5E54B",
            "#82B8FF", "#D32DDE", "#69E2E3", "#E5E5E5",
        ],
        boldForeground: "#FFFFFF"
    )

    // MARK: Solarized Dark
    // Source: github.com/altercation/solarized
    static let solarizedDark = TerminalColorTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        foreground: "#839496",
        background: "#002B36",
        ansiColors: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ],
        boldForeground: nil
    )

    // MARK: Solarized Light
    // Source: github.com/altercation/solarized
    static let solarizedLight = TerminalColorTheme(
        id: "solarized-light",
        name: "Solarized Light",
        foreground: "#657B83",
        background: "#FDF6E3",
        ansiColors: [
            "#EEE8D5", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#073642",
            "#FDF6E3", "#CB4B16", "#93A1A1", "#839496",
            "#657B83", "#6C71C4", "#586E75", "#002B36",
        ],
        boldForeground: nil
    )

    // MARK: Dracula
    // Source: spec.draculatheme.com
    static let dracula = TerminalColorTheme(
        id: "dracula",
        name: "Dracula",
        foreground: "#F8F8F2",
        background: "#282A36",
        ansiColors: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
            "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
            "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ],
        boldForeground: nil
    )

    // MARK: Nord
    // Source: nordtheme.com
    static let nord = TerminalColorTheme(
        id: "nord",
        name: "Nord",
        foreground: "#D8DEE9",
        background: "#2E3440",
        ansiColors: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ],
        boldForeground: nil
    )

    // MARK: Catppuccin Mocha
    // Source: github.com/catppuccin/catppuccin
    static let catppuccinMocha = TerminalColorTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        foreground: "#CDD6F4",
        background: "#1E1E2E",
        ansiColors: [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
        ],
        boldForeground: nil
    )

    // MARK: One Dark
    // Source: github.com/joshdick/onedark.vim
    static let oneDark = TerminalColorTheme(
        id: "one-dark",
        name: "One Dark",
        foreground: "#ABB2BF",
        background: "#282C34",
        ansiColors: [
            "#2C323C", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#5C6370",
            "#3E4452", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
        ],
        boldForeground: nil
    )

    // MARK: Gruvbox Dark
    // Source: github.com/morhetz/gruvbox
    static let gruvboxDark = TerminalColorTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        foreground: "#EBDBB2",
        background: "#282828",
        ansiColors: [
            "#282828", "#CC241D", "#98971A", "#D79921",
            "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F",
            "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ],
        boldForeground: nil
    )

    // SwiftTerm's built-in 16-color palette (from Colors.swift terminalAppColors).
    // Shared by both SwiftTerm Dark and SwiftTerm Light.
    private static let swiftTermAnsiColors: [String] = [
        "#000000", "#C23621", "#25BC24", "#ADAD27",
        "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
        "#818383", "#FC391F", "#31E722", "#EAEC23",
        "#5833FF", "#F933F8", "#14F0F0", "#E9EBEB",
    ]

    // MARK: SwiftTerm Dark
    // SwiftTerm's built-in palette with dark background
    static let swiftTermDark = TerminalColorTheme(
        id: "swiftterm-dark",
        name: "SwiftTerm Dark",
        foreground: "#E0E0E0",
        background: "#000000",
        ansiColors: swiftTermAnsiColors,
        boldForeground: "#FFFFFF"
    )

    // MARK: SwiftTerm Light
    // SwiftTerm's built-in palette with light background
    static let swiftTermLight = TerminalColorTheme(
        id: "swiftterm-light",
        name: "SwiftTerm Light",
        foreground: "#1A1A1A",
        background: "#FFFFFF",
        ansiColors: swiftTermAnsiColors,
        boldForeground: "#000000"
    )

    // MARK: Alacritty Default
    // Source: alacritty.org (Base16 Eighties-derived)
    static let alacrittyDefault = TerminalColorTheme(
        id: "alacritty-default",
        name: "Alacritty Default",
        foreground: "#D8D8D8",
        background: "#181818",
        ansiColors: [
            "#181818", "#AC4242", "#90A959", "#F4BF75",
            "#6A9FB5", "#AA759F", "#75B5AA", "#D8D8D8",
            "#6B6B6B", "#C55555", "#AAC474", "#FECA88",
            "#82B8C8", "#C28CB8", "#93D3C3", "#F8F8F8",
        ],
        boldForeground: nil
    )

    // MARK: Ghostty Default
    // Source: github.com/ghostty-org/ghostty
    static let ghosttyDefault = TerminalColorTheme(
        id: "ghostty-default",
        name: "Ghostty Default",
        foreground: "#C5C8C6",
        background: "#292C33",
        ansiColors: [
            "#1D1F21", "#BF6B69", "#B7BD73", "#E9C880",
            "#88A1BB", "#AD95B8", "#95BDB7", "#C5C8C6",
            "#666666", "#C55757", "#BCC95F", "#E1C65E",
            "#83A5D6", "#BC99D4", "#83BEB1", "#EAEAEA",
        ],
        boldForeground: nil
    )

    // MARK: One Half Dark
    // Source: github.com/sonph/onehalf
    // Bright variants fixed to differentiate from normal (original has identical 1-6/9-14)
    static let oneHalfDark = TerminalColorTheme(
        id: "one-half-dark",
        name: "One Half Dark",
        foreground: "#DCDFE4",
        background: "#282C34",
        ansiColors: [
            "#282C34", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
            "#5C6370", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
        ],
        boldForeground: nil
    )
}
