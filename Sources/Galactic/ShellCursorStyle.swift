import Foundation

/// Shape of the cursor rendered in the Shell pane. Pairs
/// with `shellCursorBlink` to pick one of SwiftTerm's six
/// `CursorStyle` cases at apply time (see
/// `SwiftTermBackend.applyCursor`).
///
/// User-facing settings keep style + blink as two
/// orthogonal knobs because that's the clearer mental
/// model; the backend is where the two collapse into
/// SwiftTerm's native enum.
public enum ShellCursorStyle: String, Codable, CaseIterable {
    case block = "block"
    case underline = "underline"
    case verticalBar = "verticalBar"

    public var displayName: String {
        switch self {
        case .block: return "Block"
        case .underline: return "Underline"
        case .verticalBar: return "Vertical Bar"
        }
    }
}
