import Foundation

/// Which keystrokes commit text and which insert a newline.
///
/// Foundation-only for the same reason as `Keystroke`: the resolver stays
/// coverable without an app or a WebView.
public struct TextEntryBindings: Codable, Equatable {
    public var submit: [Keystroke]
    public var newline: [Keystroke]

    public init(submit: [Keystroke], newline: [Keystroke]) {
        self.submit = submit
        self.newline = newline
    }

    public enum Action: String, Codable {
        case submit
        case newline
    }

    /// Resolve a keystroke to the action it triggers, or nil for "not ours".
    ///
    /// Nil is the important case: the caller passes the event through
    /// untouched rather than swallowing it, which is what leaves every key the
    /// app does not own — and every shortcut it does not know about — working
    /// exactly as before.
    ///
    /// Submit is checked first, so a keystroke appearing in both lists
    /// commits. That is a deliberate tie-break rather than an error: a binding
    /// in both lists is a state the recorder can reach, and inserting an
    /// unwanted newline is a smaller harm than dropping committed text.
    public func action(for keystroke: Keystroke) -> Action? {
        if submit.contains(keystroke) { return .submit }
        if newline.contains(keystroke) { return .newline }
        return nil
    }

    /// Claude Code's own model: a bare Return commits, Option-Return inserts a
    /// newline.
    ///
    /// Chosen to match the session pane rather than to preserve what the
    /// app-layer composers did before, so one keystroke means one thing
    /// everywhere. Two consequences are deliberate: Command-Return no longer
    /// saves, and a bare Return no longer inserts a newline in a note or
    /// annotation form.
    ///
    /// Claude Code's documented default for `chat:newline` is Ctrl+J rather
    /// than Option-Return — Option-Return is a binding you write into its
    /// keybindings file, which is what the sync does.
    ///
    /// Ctrl+J is listed here as well, and not as a courtesy: Claude Code binds
    /// it whether these defaults mention it or not, so omitting it would ship a
    /// fresh install already disagreeing with its own session pane over a key
    /// nobody chose. Naming it makes the two agree, and earns Ctrl+J the same
    /// meaning in a note form that it has always had in the pane.
    public static let `default` = TextEntryBindings(
        submit: [Keystroke(keyCode: Keystroke.Key.ret)],
        newline: [
            Keystroke(keyCode: Keystroke.Key.ret, modifiers: .option),
            Keystroke(keyCode: 38, modifiers: .control),
        ]
    )
}

extension TextEntryBindings {
    /// Replace an empty list with its default.
    ///
    /// The settings card cannot produce an empty list, but it is not the only
    /// way in: a hand-edited settings file, or adopting a shared keybindings
    /// file, both arrive here without passing through the UI. An empty submit
    /// list is the case that matters — these composers have no save button, so
    /// their text could only be discarded.
    public func coercingEmptyLists() -> TextEntryBindings {
        TextEntryBindings(
            submit: submit.isEmpty ? Self.default.submit : submit,
            newline: newline.isEmpty ? Self.default.newline : newline
        )
    }

    /// The shape the text-entry module's `configure` expects: keystrokes keyed
    /// by DOM `code`, since a WebView never sees a virtual key code.
    ///
    /// Keystrokes with no DOM spelling are dropped rather than passed along as
    /// null. A WebView cannot act on them, and sending them would let a
    /// binding look configured in the settings card while doing nothing in the
    /// composer it was meant to govern.
    public var jsPayload: [String: [[String: Any]]] {
        func encode(_ list: [Keystroke]) -> [[String: Any]] {
            list.compactMap { keystroke in
                guard let code = keystroke.domCode else { return nil }
                return [
                    "code": code,
                    "modifiers": keystroke.modifiers.rawValue,
                    // Sent rather than recomputed on the other side. The key
                    // table is large and lives here; a second copy in
                    // JavaScript would be a guaranteed source of drift, and
                    // the placeholder would eventually disagree with the
                    // settings card about the same binding.
                    "label": keystroke.displayLabel,
                ]
            }
        }
        return ["submit": encode(submit), "newline": encode(newline)]
    }
}
