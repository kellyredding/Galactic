import Foundation
import JavaScriptCore
import XCTest
@testable import Galactic

/// The cross-language contract for text-entry keystroke matching.
///
/// Two matchers decide whether a keystroke commits text or inserts a newline:
/// the Swift one, which reads macOS virtual key codes, and the JavaScript one
/// inside every composer WebView, which reads DOM `KeyboardEvent.code` because a
/// WebView never sees a virtual key code. They must agree, and the failure they
/// exist to prevent is quietly disagreeing about a chord while both look fine in
/// isolation.
///
/// Each side reads its own spelling of the same physical key from one fixture,
/// ignores the other's, and must arrive at the same answer.
///
/// This replaces two programs in two languages across two repositories — a Swift
/// smoke target and a node script, each reading its own copy of the fixture.
/// Running both sides in one process against one file is what makes disagreement
/// impossible to miss rather than merely unlikely.
final class TextEntryContractTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture: Decodable {
        let labels: [LabelCase]
        let scenarios: [Scenario]
    }

    private struct LabelCase: Decodable {
        let keyCode: UInt16
        let code: String
        let modifiers: Int
        let label: String
    }

    private struct Binding: Decodable {
        let keyCode: UInt16
        let code: String
        let modifiers: Int
    }

    private struct Scenario: Decodable {
        let name: String
        let bindings: Bindings
        let cases: [Case]

        struct Bindings: Decodable {
            let submit: [Binding]
            let newline: [Binding]
        }
    }

    private struct Case: Decodable {
        let name: String
        let keyCode: UInt16
        let code: String
        let modifiers: Int
        /// Absent means "not ours" — the caller must pass the event through.
        let expect: String?
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "text-entry-cases", withExtension: "json"
            ),
            "fixture missing from the test bundle"
        )
        return try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: url)
        )
    }

    private func swiftBindings(
        from bindings: Scenario.Bindings
    ) -> TextEntryBindings {
        TextEntryBindings(
            submit: bindings.submit.map {
                Keystroke(
                    keyCode: $0.keyCode,
                    modifiers: Keystroke.Modifiers(rawValue: $0.modifiers)
                )
            },
            newline: bindings.newline.map {
                Keystroke(
                    keyCode: $0.keyCode,
                    modifiers: Keystroke.Modifiers(rawValue: $0.modifiers)
                )
            }
        )
    }

    // MARK: - JavaScript host

    /// A context with the shipped matcher loaded, standing in for the WebView.
    private func makeJSContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext(), "no JavaScript context")
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown JavaScript exception"
        }
        // The module assigns onto `window`; a bare JSContext has no DOM, so
        // stand one up. Nothing else about a browser is needed — the matcher is
        // deliberately free of DOM access so it can be checked exactly here.
        context.evaluateScript("var window = this;")
        context.evaluateScript(textEntryJS)
        if let thrown { XCTFail("loading the matcher threw: \(thrown)") }
        return context
    }

    /// Hand the matcher the payload Swift would actually send it.
    private func configure(
        _ context: JSContext, with bindings: TextEntryBindings
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: bindings.jsPayload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        context.evaluateScript(
            "window.GalaxyTextEntry.configure(\(json));"
        )
    }

    /// Resolve one keystroke through the JavaScript matcher, shaped as the
    /// DOM event it would receive.
    private func jsAction(
        _ context: JSContext, code: String, modifiers: Int
    ) -> String? {
        let event = """
        {
            code: "\(code)",
            metaKey: \((modifiers & 1) != 0),
            altKey: \((modifiers & 2) != 0),
            ctrlKey: \((modifiers & 4) != 0),
            shiftKey: \((modifiers & 8) != 0)
        }
        """
        let result = context.evaluateScript(
            "window.GalaxyTextEntry.actionFor(\(event));"
        )
        guard let result, !result.isNull, !result.isUndefined else { return nil }
        return result.toString()
    }

    // MARK: - The contract

    /// Every case, on both sides, in one pass — so a disagreement names the
    /// scenario, the case, and which matcher was wrong.
    func testBothMatchersAgreeOnEveryFixtureCase() throws {
        let fixture = try loadFixture()
        let context = try makeJSContext()

        var checked = 0
        for scenario in fixture.scenarios {
            let bindings = swiftBindings(from: scenario.bindings)
            try configure(context, with: bindings)

            for testCase in scenario.cases {
                let where_ = "\(scenario.name) — \(testCase.name)"

                let swiftAction = bindings.action(
                    for: Keystroke(
                        keyCode: testCase.keyCode,
                        modifiers: Keystroke.Modifiers(
                            rawValue: testCase.modifiers
                        )
                    )
                )
                XCTAssertEqual(
                    swiftAction?.rawValue, testCase.expect,
                    "Swift matcher disagrees with the fixture: \(where_)"
                )

                let jsResult = jsAction(
                    context, code: testCase.code, modifiers: testCase.modifiers
                )
                XCTAssertEqual(
                    jsResult, testCase.expect,
                    "JavaScript matcher disagrees with the fixture: \(where_)"
                )

                // Stated separately from the two comparisons above: if the
                // fixture itself were ever wrong, those could both pass while
                // the matchers still disagreed with each other.
                XCTAssertEqual(
                    swiftAction?.rawValue, jsResult,
                    "the two matchers disagree with each other: \(where_)"
                )
                checked += 1
            }
        }

        XCTAssertGreaterThanOrEqual(
            checked, 19,
            "fixture shrank — cases are not supposed to disappear"
        )
    }

    /// How a binding is spelled for a person.
    ///
    /// Swift owns the key table and sends the label along with the binding, so
    /// the settings card and the composer placeholder cannot end up spelling one
    /// keystroke two ways. Both halves are checked: that Swift produces the
    /// spelling the fixture names, and that the matcher renders what it was
    /// handed rather than recomputing it.
    func testBindingLabelsMatchOnBothSides() throws {
        let fixture = try loadFixture()
        let context = try makeJSContext()

        for labelCase in fixture.labels {
            let keystroke = Keystroke(
                keyCode: labelCase.keyCode,
                modifiers: Keystroke.Modifiers(rawValue: labelCase.modifiers)
            )
            XCTAssertEqual(
                keystroke.displayLabel, labelCase.label,
                "Swift spells \(labelCase.code) differently from the fixture"
            )

            try configure(
                context,
                with: TextEntryBindings(submit: [keystroke], newline: [])
            )
            let hint = context.evaluateScript(
                "window.GalaxyTextEntry.submitHint();"
            )?.toString()
            XCTAssertEqual(
                hint, labelCase.label,
                "the matcher spells \(labelCase.code) differently"
            )
        }
    }

    /// The shipped defaults are what the fixture calls the shipped defaults.
    ///
    /// Guards the case where someone changes the default bindings and updates
    /// only the scenario that exercises them, leaving the constant and the
    /// fixture describing different products.
    func testShippedDefaultsAreTheFixturesDefaults() throws {
        let fixture = try loadFixture()
        let defaults = try XCTUnwrap(
            fixture.scenarios.first { $0.name == "shipped defaults" }
        )
        XCTAssertEqual(
            swiftBindings(from: defaults.bindings), TextEntryBindings.default
        )
    }

    /// The literal ships valid. Points the syntax gate at real cargo rather
    /// than at test samples.
    func testShippedMatcherParses() {
        XCTAssertNil(
            JavaScriptSyntax.check(textEntryJS, label: "textEntryJS")
        )
    }
}
