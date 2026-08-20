import Foundation

/// Whether any Galactic-owned modal currently holds the keyboard.
///
/// Every local key monitor in a host that answers an unmodified key — Escape,
/// a bare letter, a chord leader — has to stand down while one of these is up,
/// because none of the ordinary gates catch them: they are overlays inside the
/// host's own window, so a key-window check passes, and a reader's monitor
/// deliberately does not bail for a focused text view because its own body is
/// one.
///
/// A confirmation sheet defeats the same gate by the opposite route. It is a
/// window of its own rather than an overlay, so a key-window check would catch
/// it — but only while it holds key, and a sheet that failed to take key leaves
/// the host's window answering that check exactly when standing down matters
/// most.
///
/// One predicate rather than each monitor naming the modals it knows about.
/// The failure this prevents is the quiet kind: a new modal ships, seven
/// monitors keep answering keys behind it, and nothing reports a problem — the
/// keystroke simply does something else while the reader is looking at
/// something that should have had it. Naming the modals in one place means a
/// new one stands down everywhere at once, rather than everywhere its author
/// remembered.
///
/// AppKit does not contract the order local monitors run in, so this is a gate
/// and never an ordering assumption. "Mine installed last, therefore mine wins"
/// was tried and lost: Escape reached a reader first and closed the item behind
/// the cheat sheet instead of the sheet.
public enum GalacticModals {
    /// Nonisolated so a key monitor can ask it inside a `guard`, which is the
    /// shape every caller wants and the one place main-actor state is awkward
    /// to reach. Every call site is an event monitor or menu validation, both
    /// of which AppKit runs on the main thread.
    public static var isClaimingKeyboard: Bool {
        MainActor.assumeIsolated {
            CheatSheetPresenter.isClaimingKeyboard
                || AgentInboxPresenter.isClaimingKeyboard
                || FilePickerPresenter.isClaimingKeyboard
                || LineJumpPresenter.isClaimingKeyboard
                || SheetAlert.isClaimingKeyboard
        }
    }
}
