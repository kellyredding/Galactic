import AppKit
import Foundation

/// The keyboard a modal borrows while it is up, and the Escape that closes it.
///
/// Two presenters arrived at this independently and wrote it identically, and a
/// third was about to. What is shared is not a convenience — every line of it
/// is a bug that was found the hard way, and the arguments for each are kept
/// here rather than in the two callers so a fourth modal inherits them instead
/// of rediscovering them.
///
/// A presenter owns one of these and keeps its own presentation state. Nothing
/// here knows what is being presented, only who was interrupted.
@MainActor
final class ModalFocusCapture {

    /// Who held the keyboard when the modal opened, and where.
    ///
    /// Weak, both of them: a modal must never be the reason a window or a view
    /// outlives its host's intention to be rid of it. A responder that goes
    /// away while the modal is up simply is not restored.
    ///
    /// Internal rather than private so a test can assert they are released — a
    /// saved responder surviving a close is a retain cycle waiting for the next
    /// open.
    weak var priorWindow: NSWindow?
    weak var priorResponder: NSResponder?

    /// Live only while the modal is up. See `installEscape`.
    ///
    /// Internal rather than private so a test can assert the monitor exists
    /// exactly as long as the modal does — the claim below, and otherwise
    /// unassertable.
    var escapeMonitor: Any?

    /// Remember who holds the keyboard, so closing can hand it back.
    ///
    /// Called as the modal opens, before its overlay mounts. By the time an
    /// overlay carrying a text field has appeared, that field holds first
    /// responder, and asking then would record the modal as the thing to
    /// restore to.
    ///
    /// The window is recorded alongside the responder rather than resolved
    /// again at dismiss. A host can have a panel holding key when the modal is
    /// summoned — a find bar is the usual one — and the caret then belongs to
    /// that panel, not to the main window. Reading `keyWindow` a second time,
    /// after the overlay has taken it, would answer a different window and
    /// restore into the wrong one.
    func capture() {
        priorWindow = NSApp.keyWindow
        priorResponder = priorWindow?.firstResponder
    }

    /// Give the keyboard back to whoever had it when the modal opened.
    ///
    /// **Called by the modal's view as it disappears, not by its `dismiss`.**
    /// That is the whole correctness argument, and it was learned the hard way:
    /// restoring inside `dismiss` put the caret back and then lost it again,
    /// because a search field still bound to a focus binding that reads true
    /// makes SwiftUI clear first responder when it tears that field down — a
    /// pass or an animation later, after the restore had already happened. The
    /// window was then left with no first responder at all, which looks like
    /// neither surface being focused because that is exactly what it is.
    ///
    /// A panel has no such problem and is no guide here: it is removed
    /// synchronously and can restore immediately after. An overlay in the
    /// host's own view tree goes away when SwiftUI says so, so the only safe
    /// moment is once it has gone. Restoring last is worth a frame of no focus;
    /// restoring early is worth nothing at all.
    ///
    /// Every step is conditional, because each thing being restored may be
    /// gone: a host is free to close a reader, switch a tab, or end a session
    /// while a modal is up. Restoring nothing is the right answer then — the
    /// window keeps whatever responder it settled on.
    ///
    /// Idempotent: the note is consumed, so a second call does nothing. A host
    /// that dismisses a modal whose view never mounted leaves the note for the
    /// next open to overwrite, and both references are weak.
    func restore() {
        let window = priorWindow
        let responder = priorResponder
        priorWindow = nil
        priorResponder = nil

        guard let window, let responder else { return }
        // A view that has left the window it was saved from must not be
        // dragged back into focus: the caret belongs to whatever replaced it.
        // A responder that is not a view carries no window reference to
        // contradict, so it is trusted.
        if let view = responder as? NSView, view.window !== window { return }
        if !window.isKeyWindow { window.makeKey() }
        _ = window.makeFirstResponder(responder)
    }

    /// Install the Escape monitor that closes the modal.
    ///
    /// A local event monitor rather than `.onExitCommand` on the view: an
    /// overlay floats over surfaces that hold first responder and claim Escape
    /// for themselves — a terminal pane swallows it outright — so a SwiftUI
    /// handler never sees the key. Installed only while presented, so Escape
    /// keeps its ordinary meaning everywhere else in the host.
    ///
    /// - Parameters:
    ///   - standDown: whether something *else* owns Escape right now, in which
    ///     case the key is left alone. Named by each caller directly rather
    ///     than asked of `GalacticModals`, which counts the caller among its
    ///     own claimants — consulting it here would stand the monitor down
    ///     against itself and leave Escape unanswered whenever this modal is
    ///     the only thing up.
    ///   - isActive: whether the modal is still up. Supplied rather than
    ///     inferred, because this value does not know what it is capturing
    ///     focus for. A caller passes a weak reference to its presenter here;
    ///     a gone presenter answers false and the key passes through.
    ///   - onEscape: what closing means to the caller.
    func installEscape(
        standDown: @escaping () -> Bool,
        isActive: @escaping () -> Bool,
        onEscape: @escaping () -> Void
    ) {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            guard isActive(), !standDown(),
                event.keyCode == Keystroke.Key.esc
            else { return event }
            onEscape()
            return nil  // consumed: it must not also reach the terminal
        }
    }

    func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
