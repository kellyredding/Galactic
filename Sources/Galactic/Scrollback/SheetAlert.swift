import AppKit

/// Lightweight helper for presenting NSAlert sheet modals with a
/// consistent style across the app. All confirmation dialogs should
/// use this to guarantee visual consistency and future themeability.
public enum SheetAlert {
    /// Present a warning-style confirmation sheet attached to `window`.
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
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            } else {
                onCancel?()
            }
        }
    }
}
