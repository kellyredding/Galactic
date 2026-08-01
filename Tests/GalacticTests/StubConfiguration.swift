import AppKit
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
    var scrollToEnterScrollback = false
}
