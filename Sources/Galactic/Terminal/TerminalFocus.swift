import AppKit

/// Where focus should land, and whether that is the live terminal.
///
/// The two travel together because they are one decision: an overlay standing
/// in front of the terminal takes focus *instead of* it, and the follow-the-tail
/// re-pin belongs only to the live pane. Returning them separately invites a
/// caller to re-pin while focusing an overlay, which snaps a reader of frozen
/// history to the bottom.
public struct TerminalFocusTarget {
    public let responder: NSResponder
    public let isLivePane: Bool

    public init(responder: NSResponder, isLivePane: Bool) {
        self.responder = responder
        self.isLivePane = isLivePane
    }
}

/// Handing first responder to a terminal pane.
///
/// Both hosts had written this, and by the time the activity predicate they
/// guarded on was named the same thing on both sides, the two bodies were
/// identical but for a brace. What differs between hosts is which responder
/// should receive focus and what "the user is looking at this" means — both
/// supplied by the caller.
///
/// The deferral and the single retry are the parts worth having once. Focus is
/// requested from paths that run while AppKit is still settling — a view newly
/// in a window, a scrollback overlay being torn down, a window becoming key —
/// and a responder elsewhere may not have finished resigning. One retry on the
/// next runloop turn covers that; repeated failure means something else is
/// wrong and quietly retrying would hide it.
public enum TerminalFocus {

    /// Ask `window` to make the resolved target first responder.
    ///
    /// `resolveTarget` runs at apply time rather than call time, because what
    /// should hold focus can change between the two — an overlay may have
    /// appeared or gone in the meantime. Returning nil abandons the request.
    ///
    /// `onFocusedLivePane` runs only when focus actually landed and the target
    /// was the live pane. Hosts use it to re-pin the viewport to the tail.
    public static func request(
        in window: NSWindow?,
        isVisibleSurface: Bool,
        resolveTarget: @escaping () -> TerminalFocusTarget?,
        onFocusedLivePane: @escaping () -> Void
    ) {
        // A pane that is not the surface in front of the user does not get to
        // take the caret, however it came to be asked.
        guard isVisibleSurface else { return }
        guard let window else { return }

        DispatchQueue.main.async {
            guard let target = resolveTarget() else { return }
            let reassertFollow = {
                if target.isLivePane { onFocusedLivePane() }
            }
            if window.makeFirstResponder(target.responder) {
                reassertFollow()
                return
            }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if window.makeFirstResponder(target.responder) {
                    reassertFollow()
                }
            }
        }
    }
}
