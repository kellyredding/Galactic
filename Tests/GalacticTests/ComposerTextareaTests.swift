import Foundation
import JavaScriptCore
import XCTest
@testable import Galactic

/// How a card composer's textarea is built.
///
/// Five composers listed the same four "off" switches for themselves, three as
/// markup and two as DOM nodes. Nothing in a build or a page load notices when
/// one of them goes missing — the textarea still works, and macOS quietly
/// starts substituting text inside it, which surfaces much later as a mangled
/// path somebody pasted.
final class ComposerTextareaTests: XCTestCase {

    private var context: JSContext!
    private var thrown: String?

    override func setUpWithError() throws {
        let context = try XCTUnwrap(JSContext())
        thrown = nil
        context.exceptionHandler = { [weak self] _, exception in
            self?.thrown = exception?.toString() ?? "unknown JS exception"
        }

        context.evaluateScript("var window = this;")
        context.evaluateScript(textEntryJS)

        // A createElement stand-in that records what was set on the node. The
        // builder touches a class name, four attributes, a value and rows, so
        // a plain object covers the whole contract.
        context.evaluateScript(
            """
            var document = {
                createElement: function () {
                    return {
                        className: '',
                        value: '',
                        rows: undefined,
                        _attrs: {},
                        setAttribute: function (name, value) {
                            this._attrs[name] = value;
                        }
                    };
                }
            };
            """
        )
        context.evaluateScript(cardTextJS)

        let payload = TextEntryBindings.default.jsPayload
        let data = try XCTUnwrap(
            try? JSONSerialization.data(withJSONObject: payload)
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        context.evaluateScript("window.GalaxyTextEntry.configure(\(json));")

        self.context = context
    }

    private func assertNoThrow() {
        if let thrown { XCTFail("JS threw: \(thrown)") }
    }

    private func markup(
        _ className: String = "note-textarea",
        options: String = "{}"
    ) -> String {
        let value = context.evaluateScript(
            "window.GalaxyCardText.composerTextareaHTML("
                + "'\(className)', \(options))"
        )?.toString() ?? ""
        assertNoThrow()
        return value
    }

    private static let switchedOff = [
        "spellcheck": "false",
        "autocorrect": "off",
        "autocapitalize": "off",
        "autocomplete": "off",
    ]

    // MARK: - Markup

    func testMarkupSwitchesEverythingOff() {
        let html = markup()
        for (name, value) in Self.switchedOff {
            XCTAssertTrue(
                html.contains("\(name)=\"\(value)\""),
                "\(name) is missing from the composer markup"
            )
        }
    }

    func testMarkupCarriesTheClassAndDefaultsToOneRow() {
        let html = markup("annotation-textarea")
        XCTAssertTrue(
            html.contains("class=\"annotation-textarea\""),
            "the caller's class name must reach the markup"
        )
        XCTAssertTrue(
            html.contains("rows=\"1\""), "a composer defaults to a single row"
        )
    }

    func testMarkupTakesAnExplicitRowCount() {
        XCTAssertTrue(
            markup(options: "{ rows: 3 }").contains("rows=\"3\""),
            "an explicit row count must win over the default"
        )
    }

    /// The prompt names the key that commits, rather than asserting one the
    /// settings may have changed.
    func testPlaceholderAppendsTheConfiguredSubmitHint() {
        let html = markup(
            options: "{ placeholder: 'Add annotation', hint: 'save' }"
        )
        XCTAssertTrue(
            html.contains("placeholder=\"Add annotation"),
            "the caller's placeholder text must reach the markup"
        )
        let hint = context.evaluateScript(
            "window.GalaxyTextEntry.placeholderHint('save')"
        )?.toString() ?? ""
        XCTAssertFalse(hint.isEmpty, "the hint itself should not be empty")
        XCTAssertTrue(
            html.contains(hint),
            "the configured submit hint must be appended to the placeholder"
        )
    }

    func testPlaceholderIsLeftEmptyWhenNoneIsAsked() {
        XCTAssertTrue(
            markup().contains("placeholder=\"\""),
            "a composer with nothing to prompt gets an empty placeholder"
        )
    }

    // MARK: - The node form

    func testNodeSwitchesEverythingOff() throws {
        _ = context.evaluateScript(
            "var node = window.GalaxyCardText.createComposerTextarea("
                + "'note-edit-textarea', 'existing text', 2)"
        )
        assertNoThrow()
        for (name, value) in Self.switchedOff {
            let actual = context.evaluateScript("node._attrs['\(name)']")?
                .toString()
            XCTAssertEqual(
                actual, value, "\(name) is missing from the composer node"
            )
        }
        XCTAssertEqual(
            context.evaluateScript("node.className")?.toString(),
            "note-edit-textarea"
        )
        XCTAssertEqual(
            context.evaluateScript("node.value")?.toString(), "existing text"
        )
        XCTAssertEqual(context.evaluateScript("node.rows")?.toInt32(), 2)
    }

    func testNodeToleratesNoValueAndNoRowCount() {
        _ = context.evaluateScript(
            "var bare = window.GalaxyCardText.createComposerTextarea('c')"
        )
        assertNoThrow()
        XCTAssertEqual(context.evaluateScript("bare.value")?.toString(), "")
        XCTAssertTrue(
            context.evaluateScript("bare.rows === undefined")?.toBool() ?? false,
            "an unspecified row count must be left to the stylesheet"
        )
    }

    /// The point of the whole extraction: one source of truth, so the two
    /// construction modes cannot drift from each other. This fails if either
    /// grows an attribute the other lacks.
    func testBothConstructionModesSwitchOffTheSameThings() {
        let html = markup()
        _ = context.evaluateScript(
            "var n = window.GalaxyCardText.createComposerTextarea('c')"
        )
        let nodeNames = (
            context.evaluateScript("Object.keys(n._attrs).sort().join(',')")?
                .toString() ?? ""
        )
        .split(separator: ",").map(String.init)
        assertNoThrow()

        XCTAssertFalse(nodeNames.isEmpty, "the node form set no attributes")
        for name in nodeNames {
            XCTAssertTrue(
                html.contains("\(name)=\""),
                "the node sets \(name) but the markup does not emit it"
            )
        }
        XCTAssertEqual(
            nodeNames.count, Self.switchedOff.count,
            "the two modes must agree on the whole set"
        )
    }
}
