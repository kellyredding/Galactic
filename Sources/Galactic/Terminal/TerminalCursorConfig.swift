/// A cursor's shape and blink as one value.
///
/// Exists to be deduplicated. The engine fuses shape and blink into a single
/// cursor style, so two independent subscriptions — one per setting — would each
/// push a cursor update on their first emission, applying the same style twice
/// before the user has touched anything. Mapping both settings into one value
/// lets a single `removeDuplicates()` guard the pair.
///
/// Both apps had written this out privately and identically, which is the usual
/// sign that the reason for it belongs somewhere one reader can find it.
public struct TerminalCursorConfig: Hashable {

    public let style: ShellCursorStyle
    public let blink: Bool

    public init(style: ShellCursorStyle, blink: Bool) {
        self.style = style
        self.blink = blink
    }
}
