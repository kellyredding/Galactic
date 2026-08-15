import AppKit
import Combine
import Foundation

/// Presentation state for a ⌘/ cheat sheet: whether it is up, and the sections
/// it was opened with.
///
/// An in-window overlay, not a panel. A floating panel would reopen the
/// key/main-window questions a host's own panels already cost it, and this
/// needs none of what a panel buys. So the host mounts `CheatSheetView` in its
/// own view tree, gated on `isPresented`:
///
/// ```swift
/// @ObservedObject private var sheet = CheatSheetPresenter.shared
///
/// // …at the root of the window, above every column, so the chord reaches it
/// // from anywhere and the sheet sits outside any inactive dimming:
/// .overlay {
///     if sheet.isPresented { CheatSheetView().transition(.opacity) }
/// }
/// .animation(.easeInOut(duration: 0.12), value: sheet.isPresented)
/// ```
///
/// The sections are asked for once, as the sheet opens, and held. That is the
/// whole reason this type exists rather than the view keeping its own state:
/// the sheet's own search field takes first responder as it appears, so a host
/// resolving availability afterwards would see "the user is typing" and dim
/// every chord row.
@MainActor
public final class CheatSheetPresenter: ObservableObject {
    public static let shared = CheatSheetPresenter()

    @Published public private(set) var isPresented = false

    /// What the host handed over when the sheet opened. Meaningless while
    /// closed — and deliberately not cleared by `dismiss()`, because a host
    /// fades the overlay out and emptying this would flash a blank card on the
    /// way.
    @Published public private(set) var sections: [CheatSheetSection] = []

    /// The sheet's contents, asked for at the moment it opens.
    ///
    /// A closure rather than a stored array for the reason the find bar's
    /// metrics are one: the answer is derived from live state — user defaults,
    /// what holds focus, what is selected — so it has to be taken when the
    /// question is asked, not at launch. Threaded through here rather than
    /// through `present()` so the chord, the menu item, and anything else that
    /// opens the sheet do not each have to know about it.
    ///
    /// Asking *only* here is what makes the snapshot structural instead of a
    /// rule someone has to remember: there is no later moment at which this
    /// could be re-read, so nothing can re-read focus after the search field
    /// has taken it.
    ///
    /// A host that never sets it gets an empty sheet rather than a crash, and
    /// the view says so in words — see `CheatSheetView`'s empty state.
    public var sectionsProvider: () -> [CheatSheetSection] = { [] }

    /// Whether the cheat sheet is claiming the keyboard.
    ///
    /// Read as a stand-down gate by every other local key monitor that answers
    /// an unmodified key or the submit keystroke. While the sheet is up its
    /// search field is the only thing that should see those, and none of the
    /// ordinary gates get there: the sheet is an overlay inside the main
    /// window, so a key-window check passes, and a reader's monitor
    /// deliberately does not bail for a focused text view because its own body
    /// is one.
    ///
    /// A gate rather than an ordering assumption. AppKit does not contract the
    /// order local monitors run in, so "the sheet installed last, therefore it
    /// wins" is not something to build on — and it lost: Escape reached a
    /// reader first and closed the item behind the sheet instead of the sheet.
    ///
    /// Static because a host reads it inside a `guard` at the top of a monitor
    /// closure, where it is the whole expression.
    public static var isClaimingKeyboard: Bool { shared.isPresented }

    /// Live only while the sheet is up. See `installEscapeMonitor`.
    ///
    /// Internal rather than private so a test can assert the monitor exists
    /// exactly as long as the sheet does — the claim the doc below makes, and
    /// otherwise unassertable.
    var escapeMonitor: Any?

    /// Who held the keyboard when the sheet opened, and where. See
    /// `captureFocus`.
    ///
    /// Weak, both of them: the sheet must never be the reason a window or a
    /// view outlives its host's intention to be rid of it. A responder that
    /// goes away while the sheet is up simply is not restored.
    ///
    /// Internal rather than private so a test can assert they are released on
    /// dismiss — a saved responder surviving a close is a retain cycle waiting
    /// for the next open.
    weak var priorWindow: NSWindow?
    weak var priorResponder: NSResponder?

    /// Internal, so this package's own tests can exercise an instance without
    /// mutating the singleton every other test shares. Hosts use `shared`.
    init() {}

    /// Open with a fresh snapshot, or close if already open — so the same
    /// keystroke that summons the sheet dismisses it.
    public func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    /// Open with a fresh snapshot. A no-op when already open.
    ///
    /// Separate from `toggle()` for a host that also reaches the sheet from a
    /// menu item, where "open" and "open-or-close" are different requests.
    ///
    /// Deliberately *not* re-snapshotting an already-open sheet — which is
    /// where this parts company with the find bar's `present`, whose
    /// already-showing branch re-keys the panel because a second ⌘F means "put
    /// me back in the field". By the time this sheet is up, its own search
    /// field holds first responder, so a second snapshot would be taken with
    /// "the user is typing" true and would dim every row: the exact bug the
    /// snapshot ordering exists to prevent.
    public func present() {
        guard !isPresented else { return }
        sections = sectionsProvider()
        captureFocus()
        isPresented = true
        installEscapeMonitor()
    }

    /// Close the sheet. The keyboard goes back once the overlay is actually
    /// gone — see `restoreFocus`, which `CheatSheetView` calls on its way out.
    public func dismiss() {
        isPresented = false
        removeEscapeMonitor()
    }

    /// Remember who holds the keyboard, so closing can hand it back.
    ///
    /// Taken here for the same reason the sections are: by the time the overlay
    /// has mounted, the sheet's own search field holds first responder, and
    /// asking then would record the sheet as the thing to restore to.
    ///
    /// The window is recorded alongside the responder rather than resolved
    /// again at dismiss. A host can have a panel holding key when the sheet is
    /// summoned — a find bar is the usual one — and the caret then belongs to
    /// that panel, not to the main window. Reading `keyWindow` a second time,
    /// after the overlay has taken it, would answer a different window and
    /// restore into the wrong one.
    private func captureFocus() {
        priorWindow = NSApp.keyWindow
        priorResponder = priorWindow?.firstResponder
    }

    /// Give the keyboard back to whoever had it when the sheet opened.
    ///
    /// **Called by `CheatSheetView` as it disappears, not by `dismiss`.** That
    /// is the whole correctness argument, and it was learned the hard way:
    /// restoring inside `dismiss` put the caret back and then lost it again,
    /// because the search field is still bound to a focus binding that reads
    /// true, so SwiftUI clears first responder when it tears that field down —
    /// a pass or an animation later, after the restore had already happened.
    /// The window was then left with no first responder at all, which looks
    /// like neither surface being focused because that is exactly what it is.
    ///
    /// The find bar has no such problem and so is no guide here: it owns an
    /// `NSPanel` it removes synchronously, and can restore immediately after.
    /// An overlay in the host's own view tree goes away when SwiftUI says so,
    /// so the only safe moment is once it has gone. Restoring last is worth a
    /// frame of no focus; restoring early is worth nothing at all.
    ///
    /// Every step is conditional, because each thing being restored may be
    /// gone: a host is free to close a reader, switch a tab, or end a session
    /// while the sheet is up, and a view that has left the window must not be
    /// dragged back into focus. Restoring nothing is the right answer then —
    /// the window keeps whatever responder it settled on.
    ///
    /// Idempotent: the note is consumed, so a second call does nothing. A host
    /// that dismisses a sheet whose view never mounted simply leaves the note
    /// for the next open to overwrite, and both references are weak.
    ///
    /// Unlike the find bar's `dismiss`, this always restores when it can. That
    /// method has a sibling which deliberately clears the saved responder
    /// first, because restoring on the way out of a *pane handoff* parks focus
    /// in the outgoing pane long enough for the focus observers to record it as
    /// where the user was last. Nothing is being handed off here: the sheet is
    /// an overlay in one window and closing it is a return, not a move.
    func restoreFocus() {
        let window = priorWindow
        let responder = priorResponder
        priorWindow = nil
        priorResponder = nil

        guard let window, let responder else { return }
        // A view that has left the window it was saved from must not be
        // dragged back into focus: the host is free to close a reader, switch
        // a tab, or end a session while the sheet is up, and the caret belongs
        // to whatever replaced it. A responder that is not a view carries no
        // window reference to contradict, so it is trusted.
        if let view = responder as? NSView, view.window !== window { return }
        if !window.isKeyWindow { window.makeKey() }
        _ = window.makeFirstResponder(responder)
    }

    /// Escape closes the sheet.
    ///
    /// A local event monitor rather than `.onExitCommand` on the view: the
    /// overlay floats over surfaces that hold first responder and claim Escape
    /// for themselves — a terminal pane swallows it outright — so a SwiftUI
    /// handler never sees the key. `ScrollbackOverlayView` reaches for a
    /// monitor over the same surface for the same reason.
    ///
    /// Installed only while presented, so Escape keeps its ordinary meaning
    /// everywhere else in the host.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            // Named directly rather than asked of `GalacticModals`, which
            // counts this sheet among its claimants — consulting it here would
            // stand the monitor down against itself and leave Escape unanswered
            // whenever the cheat sheet is the only thing up.
            guard let self, self.isPresented,
                  !SheetAlert.isClaimingKeyboard,
                  event.keyCode == Keystroke.Key.esc
            else { return event }
            self.dismiss()
            return nil   // consumed: it must not also reach the terminal
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
