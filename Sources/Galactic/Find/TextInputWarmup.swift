import AppKit
import Foundation

/// One-shot warmup that primes AppKit's lazy text-input plumbing
/// — TextKit, NSSpellChecker dictionaries, NSTextInputContext,
/// Touch Bar / IME bundles, etc. — at app launch instead of
/// deferring to the user's first interaction with a text field.
///
/// Galaxy is terminal-first, so the user can run for minutes
/// before ever focusing an `NSTextField` (find bar, session
/// rename, marker name, settings input). Without this warmup,
/// the AppKit subsystems initialize on the first such focus,
/// which manifests as a multi-hundred-millisecond stall in the
/// middle of deliberate user interaction. Paying the cost at
/// launch — when latency overlaps with window appearance and
/// the user expects a moment of settling — moves the stall
/// somewhere imperceptible.
///
/// We use a real `NSTextField` (not SwiftUI's `TextField`)
/// because the find bar uses `FindTextFieldRepresentable`,
/// which wraps `NSTextField`. The path being warmed must
/// match the path being primed; SwiftUI's `TextField` runs
/// its own private `_SystemTextFieldFieldEditor` that doesn't
/// share initialization with the classic AppKit field editor.
///
/// Deferred to the next main runloop tick so the window
/// paints first; the user sees the window appear, then a
/// brief boot-up settle, then never feels the cost again.
public enum TextInputWarmup {
    public static func run(in window: NSWindow) {
        DispatchQueue.main.async {
            let dummy = NSTextField(string: "")
            dummy.frame = NSRect(
                x: -1000, y: -1000, width: 1, height: 1
            )
            dummy.isBezeled = false
            dummy.isBordered = false
            dummy.drawsBackground = false
            dummy.isHidden = true

            guard let contentView = window.contentView else {
                return
            }
            contentView.addSubview(dummy)

            // Becoming firstResponder is what triggers AppKit
            // to install + initialize the field editor and
            // associated text infrastructure. Resigning right
            // after is cheap.
            _ = window.makeFirstResponder(dummy)
            _ = window.makeFirstResponder(nil)
            dummy.removeFromSuperview()
        }
    }
}
