import AppKit
import XCTest
@testable import Galactic

/// Addressing a command to one split among several, and the ⌘W match.
///
/// Both are small and both fail quietly. An addressing rule that is too loose
/// makes every split act on a command meant for one of them — in an app with
/// one split that is indistinguishable from correct, which is exactly why it
/// needs a test rather than a try. And a ⌘W match that is too loose swallows
/// ⌘⌥W and ⌘⇧W, which then simply stop working with nothing to explain it.
final class TerminalTabCommandsTests: XCTestCase {

    // MARK: - Addressing

    func testASplitTakesACommandNamingItsOwnSession() {
        let mine = UUID()

        XCTAssertTrue(
            TerminalTabCommands.addresses(sessionID: mine, target: mine)
        )
    }

    func testASplitIgnoresACommandNamingAnotherSession() {
        XCTAssertFalse(
            TerminalTabCommands.addresses(
                sessionID: UUID(), target: UUID()
            ),
            "otherwise every split acts on a command meant for one of them"
        )
    }

    /// How an app with a single session says "this one" without an identifier.
    func testAnUnaddressedCommandReachesEverySplit() {
        XCTAssertTrue(
            TerminalTabCommands.addresses(sessionID: UUID(), target: nil)
        )
    }

    /// The same from the other side — a split with no session identity.
    func testASplitWithoutASessionTakesEverything() {
        XCTAssertTrue(
            TerminalTabCommands.addresses(sessionID: nil, target: UUID())
        )
        XCTAssertTrue(
            TerminalTabCommands.addresses(sessionID: nil, target: nil)
        )
    }

    // MARK: - The ⌘W match

    private func keyDown(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: 13
            )
        )
    }

    func testBareCommandWMatches() throws {
        XCTAssertTrue(
            TerminalTabKeyCommand.isCloseWindow(
                try keyDown("w", [.command])
            )
        )
    }

    func testUppercaseWMatches() throws {
        // A keyboard with caps lock on reports the character uppercased.
        XCTAssertTrue(
            TerminalTabKeyCommand.isCloseWindow(
                try keyDown("W", [.command])
            )
        )
    }

    func testAnotherModifierAlongsideCommandDoesNotMatch() throws {
        for extra: NSEvent.ModifierFlags in [.option, .control, .shift] {
            XCTAssertFalse(
                TerminalTabKeyCommand.isCloseWindow(
                    try keyDown("w", [.command, extra])
                ),
                "a different command must not be swallowed as ⌘W"
            )
        }
    }

    func testCommandWithoutWDoesNotMatch() throws {
        XCTAssertFalse(
            TerminalTabKeyCommand.isCloseWindow(
                try keyDown("t", [.command])
            )
        )
    }

    func testWWithoutCommandDoesNotMatch() throws {
        XCTAssertFalse(
            TerminalTabKeyCommand.isCloseWindow(try keyDown("w", []))
        )
    }

    /// Flags a full-size keyboard sets on its own must not defeat the match.
    func testIncidentalFlagsAreIgnored() throws {
        XCTAssertTrue(
            TerminalTabKeyCommand.isCloseWindow(
                try keyDown("w", [.command, .capsLock, .numericPad, .function])
            ),
            "caps lock and the pad/function bits are not modifiers anyone asked "
                + "about, so they cannot be allowed to break ⌘W"
        )
    }
}
