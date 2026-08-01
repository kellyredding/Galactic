import AppKit
import Combine
@testable import Galactic

/// A configuration whose members are all settable, so a test can vary the one
/// it is about and say nothing about the rest.
struct StubConfiguration: GalacticConfiguration {
    var terminalColorThemeName = "galaxy-default"
    var terminalFontFamily = "Menlo"
    var defaultTerminalFontSize: CGFloat = 13
    var terminalScrollbackLines = 1000
    var terminalCursorStyle: ShellCursorStyle = .block
    var terminalCursorBlink = false
    var textEntry: TextEntryBindings = .default
    var scrollToEnterScrollback = false
}

/// A configuration source a test can push changes through.
///
/// Honours the contract rather than taking the shortest route: `changes` is a
/// plain subject with no replay, so a subscriber sees exactly what the protocol
/// promises — changes only, never the current value on subscribe.
final class StubConfigurationSource: GalacticConfigurationSource {

    var current: StubConfiguration

    private let subject = PassthroughSubject<GalacticConfiguration, Never>()

    init(_ configuration: StubConfiguration = StubConfiguration()) {
        self.current = configuration
    }

    var configuration: GalacticConfiguration { current }

    var configurationChanges: AnyPublisher<GalacticConfiguration, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Change the configuration and announce it, as an app's settings store
    /// would.
    func change(_ mutate: (inout StubConfiguration) -> Void) {
        mutate(&current)
        subject.send(current)
    }
}
