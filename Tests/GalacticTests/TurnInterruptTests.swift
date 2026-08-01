import AppKit
import XCTest
@testable import Galactic

/// Recording that the user cut a turn short.
///
/// Two things have to hold and neither is visible when it stops holding: an app
/// with no turns must record nothing rather than crash, and Escape must be
/// recorded without being consumed — a keystroke swallowed here would stop the
/// abort it exists to describe.
final class TurnInterruptTests: XCTestCase {

    private func keyDown(
        keyCode: UInt16 = Keystroke.Key.esc,
        _ flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    /// Records with a turn running, which is the whole behaviour.
    func testBareEscapeDuringATurnIsRecorded() throws {
        var recorded = 0
        let interrupt: TurnInterrupt? = TurnInterrupt(
            isInTurn: { true }, record: { recorded += 1 }
        )

        interrupt.recordIfInterrupting(try keyDown())

        XCTAssertEqual(recorded, 1)
    }

    func testEscapeOutsideATurnRecordsNothing() throws {
        var recorded = 0
        let interrupt: TurnInterrupt? = TurnInterrupt(
            isInTurn: { false }, record: { recorded += 1 }
        )

        interrupt.recordIfInterrupting(try keyDown())

        XCTAssertEqual(
            recorded, 0, "there is no turn here to have been interrupted"
        )
    }

    /// The opt-out an app takes by supplying nothing. Its only requirement is
    /// that it is silent rather than fatal.
    func testNoInterruptRecorderIsHarmless() throws {
        let interrupt: TurnInterrupt? = nil

        interrupt.recordIfInterrupting(try keyDown())
    }

    /// `isInTurn` is not consulted when the keystroke was never a candidate —
    /// this monitor sees every keypress in the application, and answering
    /// "is a turn running" can mean reading state off disk.
    func testAnUnrelatedKeyDoesNotEvenAsk() throws {
        var asked = 0
        let interrupt: TurnInterrupt? = TurnInterrupt(
            isInTurn: {
                asked += 1
                return true
            },
            record: {}
        )

        interrupt.recordIfInterrupting(try keyDown(keyCode: Keystroke.Key.ret))

        XCTAssertEqual(asked, 0)
    }

    // MARK: - What counts as a bare Escape

    func testEscapeWithAModifierIsSomethingElse() throws {
        for flags: NSEvent.ModifierFlags in [
            [.command], [.control], [.option], [.shift], [.command, .shift],
        ] {
            XCTAssertFalse(
                TurnInterrupt.isBareEscape(try keyDown(flags)),
                "a modified Escape is a different request, and the terminal's"
            )
        }
    }

    /// Caps lock is not a modifier the user is holding for this keystroke, and
    /// it cannot be released to make Escape work.
    func testCapsLockDoesNotDisqualifyEscape() throws {
        XCTAssertTrue(
            TurnInterrupt.isBareEscape(try keyDown([.capsLock]))
        )
    }

    func testAnotherKeyIsNotEscape() throws {
        XCTAssertFalse(
            TurnInterrupt.isBareEscape(try keyDown(keyCode: Keystroke.Key.ret))
        )
    }
}
