import AppKit
import Combine
@testable import Galactic

/// A pane a shared terminal host can be built around without an application
/// underneath it.
///
/// Conforms through `BackendBackedPane` rather than answering the contract by
/// hand, so the double exercises the same defaults both apps' panes do and
/// cannot quietly answer something differently from the real thing.
final class StubPane: BackendBackedPane {

    let backend: TerminalBackend
    let settings: GalacticConfigurationSource
    let paneKind: TerminalPaneKind

    var isRunning = true
    var fontSize: CGFloat = 12
    var ledgerSessionId: Int64?
    var sendToClaudeTarget: SendToClaudeTarget?
    var onBell: (() -> Void)?
    var onProcessExit: ((Int32) -> Void)?

    private let fontSizeSubject = CurrentValueSubject<CGFloat, Never>(12)

    var fontSizePublisher: AnyPublisher<CGFloat, Never> {
        fontSizeSubject.eraseToAnyPublisher()
    }

    init(
        kind: TerminalPaneKind = .session,
        backend: TerminalBackend = StubBackend(),
        settings: GalacticConfigurationSource = StubConfigurationSource()
    ) {
        self.paneKind = kind
        self.backend = backend
        self.settings = settings
    }
}
