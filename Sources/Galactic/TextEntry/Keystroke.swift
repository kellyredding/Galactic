import Foundation

/// A recorded keystroke — a virtual key code plus the modifiers held with it.
///
/// Deliberately Foundation-only, with no AppKit import. Two things rest on
/// that: the smoke target links this file directly without pulling in AppKit,
/// and the matcher stays exercisable in a plain executable. The `NSEvent`
/// bridge lives in its own file for the same reason.
public struct Keystroke: Codable, Hashable {
    /// Virtual key codes this feature needs to name, so call sites and
    /// fixtures do not repeat bare numbers. Return and keypad Enter are
    /// genuinely different keys and must not be conflated — a binding on one
    /// is not a binding on the other.
    public enum Key {
        public static let ret: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let esc: UInt16 = 53
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The four modifiers a binding may name.
    ///
    /// Encodes as a bare integer rather than a nested object, so the settings
    /// file and the JavaScript twin share one wire format. A fixture table can
    /// then be read by both sides without translation, which is what keeps the
    /// two matchers from drifting apart unnoticed.
    public struct Modifiers: OptionSet, Codable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// Bit positions of the four modifiers within an `NSEvent`
        /// modifier-flags raw value.
        ///
        /// Copied here rather than read from AppKit so that
        /// `init(deviceFlags:)` — and therefore the normalisation it performs —
        /// stays linkable and testable without AppKit. The bridge asserts these
        /// still agree with the framework, so drift cannot pass silently.
        enum DeviceFlag {
            static let capsLock = 1 << 16
            static let shift = 1 << 17
            static let control = 1 << 18
            static let option = 1 << 19
            static let command = 1 << 20
            static let numericPad = 1 << 21
            static let help = 1 << 22
            static let function = 1 << 23
        }

        /// Keep only the four modifiers a binding can name, discarding
        /// caps-lock, fn, the numeric-pad flag, and the device-dependent
        /// left/right bits.
        ///
        /// Without this a match would depend on incidental modifier state:
        /// someone typing with caps-lock on, or pressing the keypad's Enter,
        /// would silently stop matching their own submit binding.
        init(deviceFlags raw: Int) {
            var result: Modifiers = []
            if raw & DeviceFlag.command != 0 { result.insert(.command) }
            if raw & DeviceFlag.option != 0 { result.insert(.option) }
            if raw & DeviceFlag.control != 0 { result.insert(.control) }
            if raw & DeviceFlag.shift != 0 { result.insert(.shift) }
            self = result
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(Int.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

extension Keystroke {
    /// One row per bindable key: how to spell it for a person, and how the DOM
    /// addresses it.
    ///
    /// Deliberately one table rather than two switches. The label and the DOM
    /// code have to cover exactly the same set of keys, and when they were
    /// separate they did not: a key with a label but no DOM code is bindable in
    /// the settings card and silently inert in every composer, because
    /// `jsPayload` drops it. Ctrl+J shipped exactly that way.
    ///
    /// Virtual key codes were read from Carbon's `kVK_*` constants rather than
    /// transcribed, since the layout is not memorable and a wrong row would
    /// bind the wrong key.
    public static let keyTable: [UInt16: (label: String, domCode: String)] = [
        0: ("A", "KeyA"), 1: ("S", "KeyS"), 2: ("D", "KeyD"),
        3: ("F", "KeyF"), 4: ("H", "KeyH"), 5: ("G", "KeyG"),
        6: ("Z", "KeyZ"), 7: ("X", "KeyX"), 8: ("C", "KeyC"),
        9: ("V", "KeyV"), 11: ("B", "KeyB"), 12: ("Q", "KeyQ"),
        13: ("W", "KeyW"), 14: ("E", "KeyE"), 15: ("R", "KeyR"),
        16: ("Y", "KeyY"), 17: ("T", "KeyT"), 31: ("O", "KeyO"),
        32: ("U", "KeyU"), 34: ("I", "KeyI"), 35: ("P", "KeyP"),
        37: ("L", "KeyL"), 38: ("J", "KeyJ"), 40: ("K", "KeyK"),
        45: ("N", "KeyN"), 46: ("M", "KeyM"),

        18: ("1", "Digit1"), 19: ("2", "Digit2"), 20: ("3", "Digit3"),
        21: ("4", "Digit4"), 22: ("6", "Digit6"), 23: ("5", "Digit5"),
        25: ("9", "Digit9"), 26: ("7", "Digit7"), 28: ("8", "Digit8"),
        29: ("0", "Digit0"),

        24: ("=", "Equal"), 27: ("-", "Minus"),
        30: ("]", "BracketRight"), 33: ("[", "BracketLeft"),
        39: ("'", "Quote"), 41: (";", "Semicolon"),
        42: ("\\", "Backslash"), 43: (",", "Comma"),
        44: ("/", "Slash"), 47: (".", "Period"),
        50: ("`", "Backquote"),

        36: ("Enter", "Enter"), 76: ("Enter", "NumpadEnter"),
        48: ("Tab", "Tab"), 49: ("Space", "Space"),
        51: ("Delete", "Backspace"), 53: ("Esc", "Escape"),
        117: ("Fwd Delete", "Delete"),

        115: ("Home", "Home"), 119: ("End", "End"),
        116: ("Page Up", "PageUp"), 121: ("Page Down", "PageDown"),

        123: ("←", "ArrowLeft"), 124: ("→", "ArrowRight"),
        125: ("↓", "ArrowDown"), 126: ("↑", "ArrowUp"),

        122: ("F1", "F1"), 120: ("F2", "F2"), 99: ("F3", "F3"),
        118: ("F4", "F4"), 96: ("F5", "F5"), 97: ("F6", "F6"),
        98: ("F7", "F7"), 100: ("F8", "F8"), 101: ("F9", "F9"),
        109: ("F10", "F10"), 103: ("F11", "F11"), 111: ("F12", "F12"),
    ]

    /// Modifier glyphs in Apple's canonical order.
    private var modifierGlyphs: String {
        var out = ""
        if modifiers.contains(.control) { out += "\u{2303}" }
        if modifiers.contains(.option) { out += "\u{2325}" }
        if modifiers.contains(.shift) { out += "\u{21e7}" }
        if modifiers.contains(.command) { out += "\u{2318}" }
        return out
    }

    /// The DOM `KeyboardEvent.code` this keystroke's key produces inside a
    /// WebView, or nil for a key outside the table.
    ///
    /// A WebView never sees a macOS virtual key code, so the JavaScript matcher
    /// compares `code` strings instead. Keeping the mapping here means the
    /// JavaScript module carries no table of its own.
    public var domCode: String? { Self.keyTable[keyCode]?.domCode }

    /// A human-readable label, in Apple's canonical modifier order.
    ///
    /// Must agree with `describeBinding` in the JavaScript module, because the
    /// settings card renders this while the composer placeholder renders that.
    /// The shared fixture table pins the pairing.
    public var displayLabel: String {
        modifierGlyphs + (Self.keyTable[keyCode]?.label ?? "Key \(keyCode)")
    }

    /// Whether this keystroke can actually reach a WebView composer. A key
    /// outside the table cannot, and the recorder refuses it rather than
    /// letting it look bound while doing nothing.
    public var isBindable: Bool { Self.keyTable[keyCode] != nil }

    /// How Claude Code spells this key in its keybindings file, or nil when its
    /// spelling is not documented.
    ///
    /// Derived from the table rather than listed beside it, so it can never
    /// name a key the table does not have. The nils are deliberate: Claude
    /// Code's schema does not constrain key strings at all, so an invented
    /// spelling would not error — it would parse, validate, and then match
    /// nothing. Guessing is strictly worse than declining.
    ///
    /// Documented in the keybindings reference: enter/return, tab, space,
    /// escape/esc, the four arrows, backspace, delete, and letters. Digits
    /// appear only in examples. Punctuation, function keys, and
    /// Home/End/PageUp/PageDown are absent from the reference entirely, so a
    /// binding on one of those reaches the composers but not the session pane.
    public var claudeKeyName: String? {
        guard let info = Self.keyTable[keyCode] else { return nil }
        switch keyCode {
        case Key.ret, Key.keypadEnter: return "enter"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 51: return "backspace"
        case 117: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            // Letters and digits are spelled as themselves. Lowercase matters:
            // a standalone uppercase letter implies Shift to Claude Code's
            // parser, which would silently add a modifier nobody asked for.
            guard info.label.count == 1,
                  let character = info.label.first,
                  character.isLetter || character.isNumber
            else { return nil }
            return info.label.lowercased()
        }
    }

    /// How Claude Code spells this whole keystroke, or nil when the key has no
    /// documented spelling.
    ///
    /// Modifiers are emitted in the order the keybindings reference uses in its
    /// own examples. The reference does not say whether order matters, so
    /// matching its examples is the safest available choice.
    public var claudeBinding: String? {
        guard let key = claudeKeyName else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Read Claude Code's spelling of a keystroke back into one of these.
    ///
    /// The inverse of `claudeBinding`, and deliberately more permissive than
    /// it: the keybindings reference documents aliases this app never emits —
    /// `return`, `control`, `command`, `meta`, `opt`, `option` — and a file
    /// somebody hand-edited is entitled to use any of them.
    ///
    /// Nil when the spelling has no representation here. The case that matters
    /// is a chord such as `ctrl+x ctrl+e`: two keystrokes pressed in sequence,
    /// which is not a single keystroke at all and cannot be made into one.
    /// Callers adopting from the file must treat nil as "leave the file alone"
    /// rather than "no binding", because the binding is real — it is only
    /// unrepresentable.
    public init?(claudeBinding: String) {
        let text = claudeBinding
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        var modifiers: Modifiers = []
        var keyName: String?
        for part in text.split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "meta": modifiers.insert(.command)
            default:
                // A second key name means a spelling this type cannot hold,
                // not a keystroke with an unusual modifier.
                guard keyName == nil else { return nil }
                keyName = part
            }
        }
        guard let keyName,
              let keyCode = Self.keyCode(forClaudeKeyName: keyName)
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// The virtual key code behind one of Claude Code's key names.
    ///
    /// Mirrors `claudeKeyName` in the other direction. Return is reachable by
    /// either spelling the reference allows, but always resolves to Return
    /// rather than keypad Enter — the file cannot distinguish them, and Return
    /// is overwhelmingly the one a binding means.
    private static func keyCode(forClaudeKeyName name: String) -> UInt16? {
        switch name {
        case "enter", "return": return Key.ret
        case "tab": return 48
        case "space": return 49
        case "escape", "esc": return 53
        case "backspace": return 51
        case "delete": return 117
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default:
            // Letters and digits spell themselves. Sorted so a label the table
            // carries twice resolves to the lower code every time, rather than
            // to whichever one the dictionary happened to hash first.
            guard name.count == 1 else { return nil }
            return keyTable
                .filter { $0.value.label.lowercased() == name }
                .keys.sorted().first
        }
    }

    /// The chord reserved for this app's own automated prompt submission.
    ///
    /// Binding it to a text-entry action would make a keystroke the user
    /// pressed indistinguishable from one the app generated, so the recorder
    /// refuses this and nothing else.
    public static let reservedMachineSubmit = Keystroke(
        keyCode: Key.ret,
        modifiers: [.control, .option, .shift, .command]
    )

}
