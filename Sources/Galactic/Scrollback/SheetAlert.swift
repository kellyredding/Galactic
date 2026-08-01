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
    /// Present a warning-style confirmation sheet attached to `window`.
    ///
    /// A `window` that cannot become main is redirected to `hostWindow()`
    /// rather than honoured. Callers reach for `NSApp.keyWindow` naturally and
    /// it is wrong whenever a floating panel holds key — so the correction lives
    /// here, once, where no call site can miss it. Passing a real window is
    /// still the clearer thing to do; this only stops the mistake from
    /// reaching the screen.
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
        alert.beginSheetModal(for: host) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            } else {
                onCancel?()
            }
        }
    }
}
