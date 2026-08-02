import AppKit

/// User-selectable terminal emulator engine. One value at a
/// time is "the global default"; per-pane construction-time
/// pinning means each pane lifecycle records which engine it
/// was constructed with and keeps it for the lifetime — so
/// flipping the global setting never affects panes already
/// running.
///
/// **One case today, and the abstraction is kept deliberately.**
/// Bringing in a second terminal backend is a live possibility
/// and this is the shape that makes it a change to this file
/// plus one new conformer, rather than a change everywhere a
/// terminal is constructed. A candidate was explored and set
/// aside as not ready; the seam outlasted the candidate on
/// purpose. Do not collapse it back into a direct
/// construction call.
///
/// `Codable` so it can ride along inside a host's own
/// settings type. No default here — an application that
/// persists this chooses what an absent value means, and
/// only one of the two applications persists it at all.
public enum TerminalEngine: String, Codable {
    case swiftTerm
}

/// Pane lifecycle classification. Today both panes use the
/// same factory entry point; the kind argument exists so
/// future engine impls that meaningfully differentiate Shell
/// vs Session usage (e.g. cursor handling, process delegate
/// shape) can specialize without changing the call sites.
/// String-backed so a host recording which pane an event came from gets a
/// stable identifier without inventing its own mapping, while routing code
/// still switches exhaustively.
public enum TerminalPaneKind: String {
    case session
    case shell
}

/// Constructs a `TerminalBackend` for the given pane kind
/// using the specified engine. The caller reads its own
/// settings at construction time and passes the answer here —
/// that is the construction-time pinning point, and it is why
/// flipping the setting cannot disturb a running pane.
///
/// The switch has one case today. Adding a second backend is
/// a case here and a new `TerminalBackend` conformer; every
/// consumer stays as it is, which is the whole reason this
/// indirection is worth its keep.
public struct TerminalBackendFactory {
    public static func make(
        engine: TerminalEngine,
        kind: TerminalPaneKind,
        frame: NSRect
    ) -> TerminalBackend {
        switch engine {
        case .swiftTerm:
            return SwiftTermBackend(frame: frame)
        }
    }
}
