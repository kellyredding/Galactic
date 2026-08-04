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
        isPresented = true
        installEscapeMonitor()
    }

    public func dismiss() {
        isPresented = false
        removeEscapeMonitor()
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
            guard let self, self.isPresented,
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
