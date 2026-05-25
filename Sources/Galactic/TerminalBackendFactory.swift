import AppKit

/// User-selectable terminal emulator engine. One value at a
/// time is "the global default"; per-pane construction-time
/// pinning means each pane lifecycle records which engine it
/// was constructed with and keeps it for the lifetime — so
/// flipping the global setting never affects panes already
/// running.
///
/// `Codable` so it rides along inside `AppSettings`. Default
/// is `.swiftTerm` for backward compatibility.
public enum TerminalEngine: String, Codable {
    case swiftTerm
    case libghostty
}

/// Pane lifecycle classification. Today both panes use the
/// same factory entry point; the kind argument exists so
/// future engine impls that meaningfully differentiate Shell
/// vs Session usage (e.g. cursor handling, process delegate
/// shape) can specialize without changing the call sites.
public enum TerminalPaneKind {
    case session
    case shell
}

/// Constructs a `TerminalBackend` for the given pane kind
/// using the specified engine. The caller (Session.init,
/// ShellTerminalPane.init, etc.) reads
/// `SettingsManager.shared.settings.terminalEngine` at its
/// own construction time and passes it here — that's the
/// D-pane construction-time pinning point. Once a libghostty
/// integration ships, this factory grows a second engine
/// case; consumers are unchanged.
public struct TerminalBackendFactory {
    public static func make(
        engine: TerminalEngine,
        kind: TerminalPaneKind,
        frame: NSRect
    ) -> TerminalBackend {
        switch engine {
        case .swiftTerm:
            return SwiftTermBackend(frame: frame)
        case .libghostty:
            // Not yet implemented. Falling back to SwiftTerm
            // keeps the app running if `terminalEngine` is
            // somehow set to `.libghostty` before the
            // integration ships (e.g. a settings file hand-
            // edited from a future build). Will become
            //   return LibghosttyBackend(frame: frame)
            // when the libghostty backend lands.
            assertionFailure(
                "libghostty engine not yet implemented; "
                + "falling back to SwiftTerm"
            )
            return SwiftTermBackend(frame: frame)
        }
    }
}
