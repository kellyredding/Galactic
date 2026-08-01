import AppKit
import Combine
import Foundation

/// Menu commands for a terminal tab, addressed to one split or to all of them.
///
/// A menu item cannot reach a SwiftUI view directly, and the split it means is
/// not necessarily the one being drawn — an app hosting several sessions has a
/// split per session, all subscribed at once. So each command carries the
/// session it is for, and every split ignores the ones that are not its own.
///
/// The identifier is optional because an app hosting exactly one session has
/// nothing to name: it sends nil, meaning "whichever split there is", and its
/// single subscriber accepts everything. That is the seam — the same commands,
/// the same subscribers, one app supplying an identifier and the other a nil.
public final class TerminalTabCommands {

    public static let shared = TerminalTabCommands()

    /// Open a shell in the addressed split, or focus the one already open.
    public let openShell = PassthroughSubject<UUID?, Never>()

    /// Move focus to the addressed split's session pane.
    public let focusSession = PassthroughSubject<UUID?, Never>()

    /// Close the addressed split's shell pane, confirming first if it holds
    /// unsaved work.
    public let closeFocusedShell = PassthroughSubject<UUID?, Never>()

    private init() {}

    /// Whether a command carrying `target` is for a split whose session is
    /// `sessionID`.
    ///
    /// A nil target addresses every split, which is how an app with one session
    /// says "this one" without having an identifier to say it with. A nil
    /// `sessionID` is a split that has no session identity — also everything,
    /// for the same reason from the other side.
    public static func addresses(
        sessionID: UUID?, target: UUID?
    ) -> Bool {
        target == nil || sessionID == nil || target == sessionID
    }
}

/// The keyboard gestures a terminal tab claims before the rest of the app sees
/// them.
public enum TerminalTabKeyCommand {

    /// Whether `event` is a bare ⌘W.
    ///
    /// Bare matters: ⌘⌥W and ⌘⇧W are different commands, and matching on
    /// "contains command" would swallow them. The check is an equality against
    /// the modifiers worth distinguishing rather than against the raw flags,
    /// because those also carry state nobody is asking about — caps lock, the
    /// numeric-pad and function bits a full-size keyboard sets on its own.
    public static func isCloseWindow(_ event: NSEvent) -> Bool {
        let interesting: NSEvent.ModifierFlags = [
            .command, .option, .control, .shift,
        ]
        guard event.modifierFlags.intersection(interesting) == .command
        else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
