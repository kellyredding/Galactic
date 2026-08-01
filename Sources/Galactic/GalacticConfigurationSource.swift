import Combine

/// Where shared code gets its configuration, and how it learns the
/// configuration changed.
///
/// `GalacticConfiguration` covers reading a configuration; this covers being
/// told about a new one. Shared code needs both and could previously only have
/// the first, so anything that had to react to a settings change named the
/// host's settings singleton directly — which is the one name that cannot come
/// along when the code moves.
///
/// ### The deduplication stays with the app
///
/// `configurationChanges` must be deduplicated before it arrives, and the app
/// has to do it: `GalacticConfiguration` is a protocol, so it cannot be
/// `Equatable`, so nothing downstream of the erasure can compare two of them.
/// The app publishes its own concrete settings type, which is `Equatable`, and
/// dedupes there.
///
/// That is not merely convenient. Both apps re-apply theme, font and scrollback
/// to every terminal on each emission, and a terminal that changes cell geometry
/// resizes the program on the other end of its PTY. An undeduplicated stream
/// makes toggling an unrelated preference repaint every full-screen program on
/// screen.
///
/// ### What the contract guarantees
///
/// - **Changes only.** The current value is not replayed to a new subscriber —
///   that is what `configuration` is for. A published property replays by
///   default, so an app conforming from one needs `dropFirst()`.
/// - **Deduplicated**, per above.
/// - **Delivered on the main thread**, because every consumer touches AppKit.
///
/// Stated here rather than left to each conformer because all three are
/// invisible when wrong: a replayed value looks like a spurious change, a
/// duplicate looks like a change that did not happen, and an off-main delivery
/// looks like an intermittent glitch somewhere else entirely.
public protocol GalacticConfigurationSource: AnyObject {

    /// The configuration as it stands now.
    var configuration: GalacticConfiguration { get }

    /// Emits each time the configuration changes — deduplicated, on main, and
    /// without replaying the current value.
    var configurationChanges: AnyPublisher<GalacticConfiguration, Never> { get }
}
