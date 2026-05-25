import Foundation

/// Text style attributes for a cell in a scrollback snapshot.
/// Each flag corresponds to an SGR (Select Graphic Rendition)
/// attribute the terminal emulator tracks per cell.
///
/// Engine-agnostic — backends translate from their internal
/// style flags (e.g. SwiftTerm's `Attribute.CellStyle` option
/// set) into this option set during snapshot iteration. Chrome
/// consumes the snapshot via this type without ever importing
/// the backend.
public struct ScrollbackAttributes: OptionSet, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// SGR 1. Renderers typically render with a thicker stroke
    /// or by promoting ansi256 colors 0-7 to their bright
    /// equivalents 8-15.
    public static let bold       = ScrollbackAttributes(rawValue: 1 << 0)

    /// SGR 3.
    public static let italic     = ScrollbackAttributes(rawValue: 1 << 1)

    /// SGR 4.
    public static let underline  = ScrollbackAttributes(rawValue: 1 << 2)

    /// SGR 7. The cell's fg/bg are swapped at draw time;
    /// renderers re-implement the swap when producing output.
    public static let inverse    = ScrollbackAttributes(rawValue: 1 << 3)

    /// SGR 2. Renderers typically blend the fg toward the bg
    /// or apply reduced opacity.
    public static let dim        = ScrollbackAttributes(rawValue: 1 << 4)

    /// SGR 8. Cell text is suppressed; the background still
    /// renders.
    public static let invisible  = ScrollbackAttributes(rawValue: 1 << 5)

    /// SGR 9.
    public static let crossedOut = ScrollbackAttributes(rawValue: 1 << 6)

    /// SGR 5 / 6.
    public static let blink      = ScrollbackAttributes(rawValue: 1 << 7)
}
