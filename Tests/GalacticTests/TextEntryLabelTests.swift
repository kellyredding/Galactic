import Foundation
import XCTest
@testable import Galactic

/// How a configured action is spelled for a reader.
///
/// Its own file because the question is Swift-only: the cross-language contract
/// covers what a keystroke *does*, and this covers what a list of them *reads
/// like* — which two different callers need to render two different ways.
final class TextEntryLabelTests: XCTestCase {

    func testEveryConfiguredKeystrokeIsNamedInOrder() {
        let bindings = TextEntryBindings(
            submit: [
                Keystroke(keyCode: Keystroke.Key.ret),
                Keystroke(keyCode: Keystroke.Key.ret, modifiers: .command),
            ],
            newline: [
                Keystroke(keyCode: Keystroke.Key.ret, modifiers: .option)
            ]
        )

        XCTAssertEqual(
            bindings.displayLabels(for: .submit), ["Enter", "⌘Enter"],
            "all of them, in the order the user configured them — a reference "
                + "that names one of two denies the other exists"
        )
        XCTAssertEqual(bindings.displayLabels(for: .newline), ["⌥Enter"])
    }

    /// Empty, not a dash and not an empty string. The two callers disagree
    /// about how to say "unbound" — a composer hint drops the clause, a
    /// reference sheet draws an em dash — and both are right where they are, so
    /// the shared layer must not pick.
    func testAnUnboundActionYieldsNoLabelsAtAll() {
        let bindings = TextEntryBindings(submit: [], newline: [])

        XCTAssertEqual(bindings.displayLabels(for: .submit), [])
        XCTAssertEqual(bindings.displayLabels(for: .newline), [])
    }

    func testTheShippedDefaultsSpellThemselves() {
        XCTAssertEqual(
            TextEntryBindings.default.displayLabels(for: .submit), ["Enter"]
        )
        XCTAssertEqual(
            TextEntryBindings.default.displayLabels(for: .newline),
            ["⌥Enter", "⌃J"]
        )
    }

    /// The labels are the same ones the settings card draws, because both read
    /// `displayLabel` — which is what keeps a reference sheet and a settings
    /// pane from spelling one keystroke two ways.
    func testTheLabelsAreTheKeystrokesOwnSpelling() {
        let keystroke = Keystroke(
            keyCode: Keystroke.Key.ret, modifiers: [.shift, .command]
        )
        let bindings = TextEntryBindings(submit: [keystroke], newline: [])

        XCTAssertEqual(
            bindings.displayLabels(for: .submit), [keystroke.displayLabel]
        )
    }
}
