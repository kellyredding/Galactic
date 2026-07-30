import AppKit
import SwiftUI

/// Bridges an `NSTextField` into SwiftUI for the find bar.
///
/// **Why an AppKit text field, not SwiftUI's `TextField`?**
/// SwiftUI's TextField bridges through a private subclass of
/// NSTextView that lazily initializes a heavy stack of macOS
/// subsystems on first focus per instance — TextKit, IME context,
/// Touch Bar candidate-list, system text replacements, etc.
/// `NSTextField` uses the cheaper shared NSTextView field editor
/// on NSWindow, which we additionally pre-warm at app launch via
/// `TextInputWarmup`.
///
/// **Focus management is intentionally not handled here.** The
/// owning panel controller (`FindBarPanelController`) calls
/// `makeFirstResponder` directly when the panel is presented and
/// dismissed. Routing focus through a SwiftUI `@Binding` here is
/// what produced "loses focus while typing": each keystroke
/// triggered a body recompute, the binding briefly read stale
/// (false) values, and `updateNSView` dispatched
/// `makeFirstResponder(nil)` async, killing focus. Removing the
/// binding eliminates the race.
///
/// The bridge is intentionally narrow — single-line plain text,
/// two keyboard shortcuts (Enter / Shift+Enter), and Esc-to-cancel.
struct FindTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let font: NSFont
    let textColor: NSColor

    /// Enter (no modifier). Convention: advance to next match.
    let onSubmit: () -> Void

    /// Shift+Enter. Convention: previous match.
    let onShiftSubmit: () -> Void

    /// Esc. Convention: close the find bar.
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.lineBreakMode = .byClipping
        tf.placeholderString = placeholder
        tf.font = font
        tf.textColor = textColor
        tf.delegate = context.coordinator
        tf.stringValue = text

        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        // Keep coordinator's closures fresh — view re-renders
        // capture new closures each time.
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onShiftSubmit = onShiftSubmit
        context.coordinator.onCancel = onCancel

        // Keep the field's text in sync with the binding
        // without clobbering the user's in-flight typing.
        // controlTextDidChange (user input) writes the binding;
        // setting stringValue here only fires when the binding
        // moved for some other reason (programmatic clear,
        // reader swap, etc.).
        if tf.stringValue != text {
            tf.stringValue = text
        }

        // No focus mutation here. See type doc-comment.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onShiftSubmit: onShiftSubmit,
            onCancel: onCancel
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onShiftSubmit: () -> Void
        var onCancel: () -> Void

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onShiftSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onShiftSubmit = onShiftSubmit
            self.onCancel = onCancel
        }

        // MARK: NSTextFieldDelegate

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            // Mutating the binding inside the delegate callback
            // is allowed (we're already on main); SwiftUI will
            // schedule the dependent updates on its own cycle.
            text = tf.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Enter / Shift+Enter. Single-line NSTextField
                // routes both through insertNewline:; we sniff
                // the shift state from the current event.
                let shift = NSApp.currentEvent?
                    .modifierFlags
                    .contains(.shift) ?? false
                if shift {
                    onShiftSubmit()
                } else {
                    onSubmit()
                }
                // Returning true keeps the field editor from
                // committing-and-blurring; the user can chain
                // Enter presses to walk through matches.
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true

            default:
                return false
            }
        }
    }
}
