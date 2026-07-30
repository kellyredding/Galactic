import JavaScriptCore
import XCTest
@testable import Galactic

/// The shared substrate both card managers stand on.
final class CardTextTests: XCTestCase {

    /// Anything thrown by the context, kept per test so a failure names the
    /// throw rather than surfacing as an unexplained `undefined` result.
    private var thrown: String?

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        thrown = nil
        context.exceptionHandler = { [weak self] _, value in
            self?.thrown = value?.toString()
        }
        context.evaluateScript("var window = this;")
        // The module dispatches an input event so the autosize listener sees
        // the text it just inserted. A bare context has no DOM, so stand up
        // just enough of one for the call to be made.
        context.evaluateScript("var Event = function (type) { this.type = type; };")
        context.evaluateScript(cardTextJS)
        if let thrown { XCTFail("loading the module threw: \(thrown)") }
        return context
    }

    /// Fails with the JavaScript exception when one was thrown.
    private func assertNoThrow(_ line: UInt = #line) {
        if let thrown {
            XCTFail("JavaScript threw: \(thrown)", line: line)
        }
    }

    private func number(_ context: JSContext, _ expression: String) -> Int32? {
        context.evaluateScript(expression)?.toInt32()
    }

    func testModuleInstallsItsSurface() throws {
        let context = try makeContext()
        for member in [
            "EDIT_ICON_SVG", "DELETE_ICON_SVG",
            "DELETE_ARM_REJECT_MS", "DELETE_REVERT_MS",
            "armDeleteButton", "disarmDeleteButton",
            "installAutosize", "insertPaths",
        ] {
            let present = context.evaluateScript(
                "typeof window.GalaxyCardText.\(member) !== 'undefined';"
            )?.toBool()
            XCTAssertEqual(present, true, "\(member) missing from the module")
        }
    }

    func testInjectingTwiceIsANoOp() throws {
        let context = try makeContext()
        context.evaluateScript("window.GalaxyCardText.__marker = 1;")
        context.evaluateScript(cardTextJS)
        XCTAssertEqual(
            context.evaluateScript("window.GalaxyCardText.__marker;")?.toInt32(),
            1,
            "a second injection replaced the module instead of returning"
        )
    }

    /// The one cross-language invariant in the card UI.
    ///
    /// An armed delete button shows a draining bar and disarms itself when the
    /// bar empties. The bar is a CSS animation and the disarm is a JavaScript
    /// timer, so the two durations have to be written twice — and until both
    /// halves lived here, they were written in two languages in two packages,
    /// where nothing could compare them. A bar that empties before or after the
    /// button disarms reads as the button being broken.
    func testDeleteRevertMatchesTheDrainAnimation() throws {
        let context = try makeContext()
        let revertMS = try XCTUnwrap(
            number(context, "window.GalaxyCardText.DELETE_REVERT_MS;")
        )
        XCTAssertEqual(revertMS, 5000)

        let css = deleteConfirmCSS(prefix: "note")
        XCTAssertTrue(
            css.contains("animation: confirmDrain \(revertMS / 1000)s"),
            "the drain animation and the disarm timer disagree — "
                + "timer is \(revertMS)ms and the CSS says otherwise"
        )
    }

    /// Rejecting a click this soon after arming is what stops a double-click
    /// from arming and confirming a delete in one gesture.
    func testArmRejectWindowIsShorterThanTheRevertWindow() throws {
        let context = try makeContext()
        let reject = try XCTUnwrap(
            number(context, "window.GalaxyCardText.DELETE_ARM_REJECT_MS;")
        )
        let revert = try XCTUnwrap(
            number(context, "window.GalaxyCardText.DELETE_REVERT_MS;")
        )
        XCTAssertEqual(reject, 500)
        XCTAssertLessThan(
            reject, revert,
            "a reject window at or beyond the revert window would make the "
                + "button impossible to confirm"
        )
    }

    // MARK: - Path insertion

    /// Exercised against a stand-in rather than a real textarea: the function
    /// touches only `value`, the two selection offsets, and two methods, so a
    /// plain object covers the whole contract without a DOM.
    private func insertPaths(
        _ context: JSContext, into value: String, caret: Int, paths: [String]
    ) -> String? {
        let list = paths.map { "'\($0)'" }.joined(separator: ", ")
        return context.evaluateScript(
            """
            (function () {
                var ta = {
                    value: '\(value)',
                    selectionStart: \(caret),
                    selectionEnd: \(caret),
                    dispatchEvent: function () {},
                    focus: function () {}
                };
                window.GalaxyCardText.insertPaths(ta, [\(list)]);
                return ta.value;
            })();
            """
        )?.toString()
    }

    func testPathsAreBracketedAndPlacedOnTheirOwnLine() throws {
        let context = try makeContext()
        let result = insertPaths(
            context, into: "notes", caret: 5, paths: ["/tmp/a b.txt"]
        )
        assertNoThrow()
        XCTAssertEqual(result, "notes\n[/tmp/a b.txt]\n")
    }

    /// No leading newline when the caret already sits at the start of a line —
    /// otherwise a drop into an empty box opens with a blank row.
    func testNoLeadingNewlineAtTheStartOfALine() throws {
        let context = try makeContext()
        XCTAssertEqual(
            insertPaths(context, into: "", caret: 0, paths: ["/tmp/a"]),
            "[/tmp/a]\n"
        )
    }

    func testMultiplePathsShareOneLine() throws {
        let context = try makeContext()
        XCTAssertEqual(
            insertPaths(context, into: "", caret: 0, paths: ["/a", "/b"]),
            "[/a] [/b]\n"
        )
    }

    func testEmptyDropIsIgnored() throws {
        let context = try makeContext()
        XCTAssertEqual(
            insertPaths(context, into: "kept", caret: 4, paths: []), "kept"
        )
    }
}
