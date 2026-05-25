import Foundation

/// Cell foreground or background color in a scrollback snapshot.
/// Mirrors the four shapes a terminal emulator can produce: the
/// theme default, the inverse-with-default-color sentinel that
/// SwiftTerm produces when SGR-inverse is applied to a default-
/// colored cell, indexed palette colors (the standard 256-color
/// surface), and direct 24-bit truecolor.
///
/// Engine-agnostic — backends translate from their internal
/// representations (e.g. SwiftTerm's `Attribute.Color`) into
/// these cases during snapshot iteration. Chrome consumes the
/// snapshot via this enum without ever importing the backend.
public enum ScrollbackColor: Equatable {
    /// The theme's default foreground (for fg cells) or
    /// background (for bg cells). Chrome resolves via its own
    /// `TerminalColorTheme`.
    case defaultColor

    /// SGR-inverse applied to a default-colored cell — the
    /// cell's fg/bg got swapped by the emulator, but the
    /// originating color was the default. Chrome typically
    /// renders this as the theme's opposite-side color (theme
    /// background when used as fg, theme foreground when used
    /// as bg).
    case defaultInvertedColor

    /// Indexed palette color (0-255). 0-15 are the base + bright
    /// ANSI colors, 16-231 are the 6×6×6 RGB cube, 232-255 are
    /// the grayscale ramp.
    case ansi256(UInt8)

    /// Direct 24-bit truecolor.
    case trueColor(red: UInt8, green: UInt8, blue: UInt8)
}
