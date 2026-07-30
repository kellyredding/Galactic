import Foundation

/// The terminal identity this app declares to the programs it launches.
///
/// Both panes claim it, and the reasoning is subtle enough that a second copy
/// would drift from this one — where the symptom of drift is a keystroke that
/// silently never arrives. So the claim, the reasons for it, and the inherited
/// state it has to displace live together here.
public enum TerminalIdentity {
    /// Claude Code enables the kitty keyboard protocol only for an allowlisted
    /// terminal identity, and that protocol is what carries a modified Return —
    /// without it Command-Return reaches the child as a bare carriage return,
    /// indistinguishable from Return itself.
    ///
    /// "kitty" is the safest name on that list: unlike ghostty, iTerm.app, or
    /// Apple_Terminal it drives no other behaviour in Claude Code. Declaring it
    /// rather than setting `TERM=xterm-kitty` also leaves terminfo alone for
    /// every other program sharing the pane.
    ///
    /// The engine implements kitty's *keyboard* protocol and not its *graphics*
    /// protocol, which is what makes the claim affordable in a general-purpose
    /// shell as well as a Claude session: a program that believes it and
    /// transmits an image gets nothing rendered, because the APC payload is
    /// parsed and dropped rather than printed as text. The residue is a tool
    /// that stalls waiting for a graphics reply that never comes, or one that
    /// shells out to a `kitty` binary that is not installed. Both are visible
    /// and neither corrupts the screen.
    public static let program = "kitty"

    /// Environment entries describing whichever terminal launched this app.
    ///
    /// Dropped before the claim is made. An inherited identity would either win
    /// outright or leave a version or session string describing a different
    /// terminal than the one now being claimed — and a half-replaced identity is
    /// harder to diagnose than an absent one, because each field looks
    /// plausible on its own.
    public static let inheritedPrefixes = [
        "TERM_PROGRAM=",
        "TERM_PROGRAM_VERSION=",
        "TERM_SESSION_ID=",
    ]

    /// Whether an environment entry describes an inherited terminal identity.
    public static func isInherited(_ entry: String) -> Bool {
        inheritedPrefixes.contains { entry.hasPrefix($0) }
    }

    /// The entry that declares this app's own identity.
    ///
    /// Deliberately only the program name: the app is not the kitty version it
    /// names, so claiming a version would be inventing one, and no session id is
    /// offered because nothing here mints them.
    public static var declaration: String { "TERM_PROGRAM=\(program)" }
}
