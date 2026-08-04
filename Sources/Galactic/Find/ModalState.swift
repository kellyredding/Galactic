import AppKit

/// Detects whether a modal presentation is currently on top of a
/// given window. Drag-and-drop targets call this to refuse drops
/// while the user is being asked to make a modal decision —
/// preventing both the stale-render bug (drop bytes accepted but
/// view not repainted until a later event) and the broader UX
/// issue of accepting input the user can't see they're directing.
///
/// Four mechanisms are covered:
/// 1. App-modal windows presented via `NSApp.runModal(for:)`
///    (Settings, New Session, Restore Session).
/// 2. Window-modal sheets presented via
///    `NSAlert.beginSheetModal(for:)` — every confirmation dialog
///    in the app goes through `SheetAlert.confirm`, which uses
///    this mechanism.
/// 3. The find bar, a floating child panel. Not modal in AppKit's
///    sense, but it sits over the scrollback holding the keyboard,
///    so a drop landing behind it has the same problem: input
///    directed somewhere the user isn't looking.
/// 4. The cheat sheet, an in-window overlay. Also not modal, and
///    also holding the keyboard: its search field is the only
///    thing that should see an unmodified key while it is up.
///    Registered here rather than as a host-side flag because at
///    least one Escape consumer lives inside this package and an
///    app-side flag cannot reach it.
///
/// If a fifth presentation mechanism is added later, extend this
/// helper rather than the individual drag handlers.
public enum ModalState {
    /// True when a modal is currently presenting over `window`.
    /// Pass the drag-target view's own `window` — sheet
    /// attachment is per-window, so the helper needs the context.
    @MainActor
    public static func isPresenting(over window: NSWindow?) -> Bool {
        if NSApp.modalWindow != nil { return true }
        if window?.attachedSheet != nil { return true }
        if FindBarPanelController.shared.isPresenting { return true }
        if CheatSheetPresenter.shared.isPresented { return true }
        return false
    }
}
