import AppKit

/// Whether a click on a picker row is asking for the panel to stay open.
///
/// Read from `NSEvent` because a SwiftUI tap handler is handed no modifier
/// state, and gating a second gesture on `.modifiers(.command)` would leave two
/// tap gestures on one row to be resolved against each other. The flags are
/// still held when the handler runs, which is what makes a static read answer
/// the click being delivered.
enum FilePickerClick {
    static var wantsToKeepOpen: Bool {
        NSEvent.modifierFlags.contains(.command)
    }
}
