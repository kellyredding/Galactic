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
        context.evaluateScript(
            "var Event = function (type, init) {"
                + " this.type = type;"
                + " this.bubbles = !!(init && init.bubbles); };"
        )
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
                    focused: false,
                    events: [],
                    setSelectionRange: function (s, e) {
                        this.selectionStart = s;
                        this.selectionEnd = e;
                    },
                    dispatchEvent: function (e) {
                        // Records order: focus must already have happened.
                        this.events.push({
                            type: e.type,
                            bubbles: !!e.bubbles,
                            focusedFirst: this.focused
                        });
                    },
                    focus: function () { this.focused = true; }
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

    /// Focus is taken before the input event is dispatched.
    ///
    /// The listeners that event wakes can reflow the surface — on a surface
    /// whose cards are absolutely positioned, growing this box moves
    /// everything below it. Focusing afterwards lands on an element the layout
    /// has already moved, and the caret is lost even though the text arrived.
    /// The suggestion-insert path has always done it in this order; the drop
    /// path had it reversed.
    func testFocusIsTakenBeforeTheInputEventIsDispatched() throws {
        let context = try makeContext()
        let ordered = context.evaluateScript(
            """
            (function () {
                var ta = {
                    value: '', selectionStart: 0, selectionEnd: 0,
                    focused: false, focusedFirst: null,
                    setSelectionRange: function (s, e) {
                        this.selectionStart = s; this.selectionEnd = e;
                    },
                    dispatchEvent: function (e) {
                        this.focusedFirst = this.focused;
                        this.bubbled = !!e.bubbles;
                    },
                    focus: function () { this.focused = true; }
                };
                window.GalaxyCardText.insertPaths(ta, ['/tmp/a']);
                return ta.focusedFirst === true && ta.bubbled === true;
            })();
            """
        )?.toBool()
        assertNoThrow()
        XCTAssertEqual(
            ordered, true,
            "insertPaths must focus before dispatching, and the event must bubble"
        )
    }

    func testEmptyDropIsIgnored() throws {
        let context = try makeContext()
        XCTAssertEqual(
            insertPaths(context, into: "kept", caret: 4, paths: []), "kept"
        )
    }
}
