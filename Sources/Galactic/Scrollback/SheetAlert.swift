import AppKit

/// Lightweight helper for presenting NSAlert sheet modals with a
/// consistent style across the app. All confirmation dialogs should
/// use this to guarantee visual consistency and future themeability.
public enum SheetAlert {

    /// The window a confirmation sheet should hang from.
    ///
    /// Not `NSApp.keyWindow`, which is the trap: a floating panel can take key
    /// while remaining incapable of being main, and the find bar is exactly
    /// that. Ask the key window while the find bar is up and you get the find
    /// bar — so a full-width alert ends up attached to a small borderless panel
    /// parked in a corner, laid out against a frame that cannot hold it, and
    /// modal to a window that cannot be the app's main one.
    ///
    /// `NSApp.mainWindow` is the right question because a panel declining main
    /// is precisely how it says "I am not the thing your document lives in".
    /// The fallbacks keep that property: a key window is only accepted if it
    /// could have been main anyway, and the last resort scans for a visible
    /// window that could.
    ///
    /// Main-thread only by expectation rather than annotation, like the
    /// presentation below it: every caller is already on main, and annotating
    /// would force `await` through Combine sinks that are not main-actor-typed
    /// while fixing no defect.
    public static func hostWindow() -> NSWindow? {
        host(
            mainWindow: NSApp.mainWindow,
            keyWindow: NSApp.keyWindow,
            windows: NSApp.windows
        )
    }

    /// The resolution itself, taking its inputs so it can be exercised without
    /// an application around it.
    static func host(
        mainWindow: NSWindow?,
        keyWindow: NSWindow?,
        windows: [NSWindow]
    ) -> NSWindow? {
        if let mainWindow { return mainWindow }
        if let keyWindow, keyWindow.canBecomeMain { return keyWindow }
        return windows.first { $0.isVisible && $0.canBecomeMain }
    }
    /// Whether a confirmation sheet is on screen.
    ///
    /// A sheet is modal to its window, but its key events still travel through
    /// `NSApp` — so every local monitor in the host sees them, and any that
    /// answers an unmodified key answers this one too: Return reaching a list
    /// chord instead of the default button, Escape closing a reader instead of
    /// cancelling the question. The ordinary gate does not catch it. A monitor
    /// asking whether the host's own window is key is answered `true` in
    /// precisely the case that matters, because a sheet that failed to take key
    /// is a sheet whose parent still holds it.
    ///
    /// Counted rather than flagged because sheets queue: a second confirmation
    /// raised while one is up must not drop the claim when the first is
    /// answered.
    public static var isClaimingKeyboard: Bool { presentedCount > 0 }

    /// Main-thread only, like the presentation below it — `nonisolated(unsafe)`
    /// states that discipline rather than proving it, the same trade the log
    /// sink makes.
    nonisolated(unsafe) private static var presentedCount = 0

    /// Present a warning-style confirmation sheet attached to `window`.
    ///
    /// A `window` that cannot become main is redirected to `hostWindow()`
    /// rather than honoured. Callers reach for `NSApp.keyWindow` naturally and
    /// it is wrong whenever a floating panel holds key — so the correction lives
    /// here, once, where no call site can miss it. Passing a real window is
    /// still the clearer thing to do; this only stops the mistake from
    /// reaching the screen.
    ///
    /// Resolving a host answers which window the sheet hangs from, which is a
    /// different question from whether that window can hear the answer. A sheet
    /// is offered the keyboard only while its parent is key and the app is
    /// active, and neither is established anywhere else on this path — so a
    /// sheet could arrive whose default button Return could not reach, leaving
    /// the user to find the mouse. Both are taken here, unconditionally.
    ///
    /// Unconditionally is a choice worth naming: every caller raises a
    /// confirmation in reply to something the user just did, so taking
    /// activation is what they already expect. A caller that ever wants to ask
    /// a question in the background — while the user works in another app —
    /// needs an opt-out added here rather than a sheet that quietly steals the
    /// screen, because that caller's whole point is not to.
    ///
    /// - Parameters:
    ///   - window: The window to attach the sheet to.
    ///   - message: Bold header text (e.g. "Discard annotation?").
    ///   - detail: Explanatory text below the header.
    ///   - confirm: Title for the primary (destructive) button.
    ///   - onConfirm: Called when the user clicks the confirm button.
    ///   - onCancel: Called when the user clicks Cancel (optional).
    public static func confirm(
        in window: NSWindow,
        message: String,
        detail: String,
        confirm confirmTitle: String = "Discard",
        onConfirm: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        guard let host = window.canBecomeMain ? window : hostWindow() else {
            return
        }

        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        host.makeKeyAndOrderFront(nil)

        // Claimed before presenting and released before the answer is
        // delivered, so a callback that raises another question or moves focus
        // reads a claim that already reflects this sheet being gone.
        presentedCount += 1
        alert.beginSheetModal(for: host) { response in
            presentedCount -= 1
            if response == .alertFirstButtonReturn {
                onConfirm()
            } else {
                onCancel?()
            }
        }

        // Asking once is not the same as succeeding. `beginSheetModal` returns
        // before the sheet is on screen, so the activation above lands in a gap
        // the sheet has not filled yet — and a caller that decided
        // asynchronously may have arrived here with the app already behind
        // another one.
        giveKeyboard(
            to: alert.window, over: host, attempt: 0, hasAppeared: false
        )
    }

    /// How long to keep asking, and how often. Roughly half a second, which is
    /// the span over which an activation race resolves — long enough to outlast
    /// one, short enough that a sheet nobody can focus fails visibly instead of
    /// leaving the app tugging at the screen.
    static let maxAttempts = 12
    static let retryInterval = 0.04

    /// What one pass of the focus loop should do.
    enum KeyboardNudge: Equatable {
        /// Nothing left to do: the sheet has the keyboard, or has been
        /// answered, or has refused long enough to stop asking.
        case stop
        /// On screen without the keyboard — the failure being corrected.
        case nudge
        /// Not on screen yet. Sheets are presented asynchronously and queue
        /// behind each other, so absence this early means "not yet", not "no".
        case wait
    }

    /// The decision itself, taking its inputs so it can be exercised without an
    /// application around it — the same trade `host(_:_:_:)` makes above.
    ///
    /// The third stop condition is the one worth pinning. A loop watching only
    /// for success keeps firing after the user answers, and every pass
    /// re-activates the app — so answering a sheet and immediately switching
    /// away would drag them back for the rest of the loop. A sheet that
    /// appeared and is now gone has been answered, so appearance has to be
    /// carried rather than read once: `isVisible` is equally false before a
    /// sheet attaches, and treating that as dismissal would abandon the fix in
    /// exactly the case it exists for.
    static func nudge(
        sheetIsKey: Bool,
        sheetIsVisible: Bool,
        hasAppeared: Bool,
        attempt: Int
    ) -> KeyboardNudge {
        if sheetIsKey { return .stop }
        if hasAppeared, !sheetIsVisible { return .stop }
        guard attempt < maxAttempts else { return .stop }
        return sheetIsVisible ? .nudge : .wait
    }

    /// Keep asking until `sheet` holds the keyboard, then stop.
    ///
    /// The parent is the lever, never the sheet: AppKit hands key to an
    /// attached sheet once the parent is key and the app is active, and a
    /// sheet's own window is not something to order about — that is the
    /// mechanism sheets are built on, not an implementation detail to reach
    /// past.
    ///
    /// Main-thread only by expectation rather than annotation, like the
    /// presentation above it.
    private static func giveKeyboard(
        to sheet: NSWindow,
        over host: NSWindow,
        attempt: Int,
        hasAppeared: Bool
    ) {
        let appeared = hasAppeared || sheet.isVisible

        switch nudge(
            sheetIsKey: sheet.isKeyWindow,
            sheetIsVisible: sheet.isVisible,
            hasAppeared: appeared,
            attempt: attempt
        ) {
        case .stop:
            return
        case .nudge:
            NSApp.activate()
            host.makeKeyAndOrderFront(nil)
        case .wait:
            break
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            [weak sheet, weak host] in
            guard let sheet, let host else { return }
            giveKeyboard(
                to: sheet,
                over: host,
                attempt: attempt + 1,
                hasAppeared: appeared
            )
        }
    }
}
