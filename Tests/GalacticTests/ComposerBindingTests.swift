import Foundation
import JavaScriptCore
import XCTest
@testable import Galactic

/// What a card composer does with a keystroke.
///
/// Five composers — the create forms and the in-card edit textareas on both
/// card surfaces — each spelled out the same listener: let an open emoji popup
/// claim the key, then submit, then newline. The generic half of that already
/// existed in the keystroke module and had never been wired to anything.
///
/// These pin the composed behavior, including the part the surfaces disagree
/// about: one answers Escape on the textarea and the other reports its context
/// to a host, so claiming Escape has to be opt-in. A composer that claimed it
/// unconditionally would swallow the key on the surface that needs it to
/// travel.
final class ComposerBindingTests: XCTestCase {

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
        context.evaluateScript(cardTextJS)

        // Bindings the tests can reason about: bare Return submits, and
        // Shift+Return inserts a newline. These are the shipped defaults, and
        // fixing them here keeps the assertions about the wiring rather than
        // about whatever the default happens to be.
        let payload = TextEntryBindings.default.jsPayload
        let data = try XCTUnwrap(
            try? JSONSerialization.data(withJSONObject: payload)
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        context.evaluateScript("window.GalaxyTextEntry.configure(\(json));")

        // A textarea and an event, standing in for the DOM. The binding reads
        // the key fields and calls the two event methods, so a plain object
        // covers the whole contract.
        context.evaluateScript(
            """
            var log = [];
            var emojiClaims = false;
            var EmojiAutocomplete = {
                handleKeyDown: function () {
                    if (emojiClaims) { log.push('emoji'); return true; }
                    return false;
                }
            };
            var ta = {
                value: '',
                selectionStart: 0,
                selectionEnd: 0,
                _listeners: {},
                addEventListener: function (type, fn) {
                    this._listeners[type] = fn;
                },
                setSelectionRange: function (s, e) {
                    this.selectionStart = s; this.selectionEnd = e;
                },
                dispatchEvent: function () {}
            };
            function press(init) {
                var e = {
                    key: init.key,
                    code: init.code || '',
                    keyCode: init.keyCode || 0,
                    metaKey: !!init.metaKey,
                    ctrlKey: !!init.ctrlKey,
                    altKey: !!init.altKey,
                    shiftKey: !!init.shiftKey,
                    defaultPrevented: false,
                    propagationStopped: false,
                    preventDefault: function () {
                        this.defaultPrevented = true;
                    },
                    stopPropagation: function () {
                        this.propagationStopped = true;
                    }
                };
                ta._listeners['keydown'](e);
                return e;
            }
            """
        )
        self.context = context
    }

    private func assertNoThrow() {
        if let thrown { XCTFail("JS threw: \(thrown)") }
    }

    private func bind(escape: Bool) {
        let escapeHandler = escape
            ? "onEscape: function () { log.push('escape'); }"
            : ""
        let comma = escape ? "," : ""
        context.evaluateScript(
            """
            window.GalaxyCardText.bindCardComposer(ta, {
                onSubmit: function () { log.push('submit'); }\(comma)
                \(escapeHandler)
            });
            """
        )
        assertNoThrow()
    }

    private var log: [String] {
        context.evaluateScript("log.join(',')")?.toString()
            .split(separator: ",").map(String.init) ?? []
    }

    /// Return is the shipped submit keystroke.
    private func pressReturn(shift: Bool = false) -> JSValue? {
        let value = context.evaluateScript(
            "press({ key: 'Enter', code: 'Enter', keyCode: 13,"
                + " shiftKey: \(shift) })"
        )
        assertNoThrow()
        return value
    }

    // MARK: - Submit and newline

    func testSubmitKeystrokeCallsSubmitAndClaimsTheKey() throws {
        bind(escape: false)
        let event = try XCTUnwrap(pressReturn())
        XCTAssertEqual(log, ["submit"], "the submit keystroke must call onSubmit")
        XCTAssertTrue(
            event.objectForKeyedSubscript("defaultPrevented").toBool(),
            "submitting must prevent the textarea inserting a newline too"
        )
    }

    func testNewlineKeystrokeDoesNotSubmit() throws {
        bind(escape: false)
        _ = pressReturn(shift: true)
        XCTAssertEqual(
            log, [], "the newline keystroke must not reach onSubmit"
        )
    }

    // MARK: - The emoji popup's first claim

    /// While the popup is open the same keys mean navigate and select. If the
    /// composer acted first, choosing an emoji with Return would submit the
    /// form instead.
    func testAnOpenEmojiPopupClaimsTheKeyBeforeSubmit() throws {
        bind(escape: false)
        context.evaluateScript("emojiClaims = true;")
        _ = pressReturn()
        XCTAssertEqual(
            log, ["emoji"],
            "the popup must consume the key without the composer submitting"
        )
    }

    // MARK: - Escape, opt in and opt out

    func testEscapeIsClaimedWhenAHandlerIsSupplied() throws {
        bind(escape: true)
        let event = try XCTUnwrap(
            context.evaluateScript("press({ key: 'Escape' })")
        )
        assertNoThrow()
        XCTAssertEqual(log, ["escape"], "the supplied handler must run")
        XCTAssertTrue(
            event.objectForKeyedSubscript("defaultPrevented").toBool(),
            "claiming Escape must prevent the default"
        )
        XCTAssertTrue(
            event.objectForKeyedSubscript("propagationStopped").toBool(),
            "claiming Escape must stop it reaching the surface's own handler"
        )
    }

    /// The surface that answers Escape elsewhere needs the key to travel. A
    /// composer that stopped propagation regardless would strand it.
    func testEscapeIsLeftAloneWhenNoHandlerIsSupplied() throws {
        bind(escape: false)
        let event = try XCTUnwrap(
            context.evaluateScript("press({ key: 'Escape' })")
        )
        assertNoThrow()
        XCTAssertEqual(log, [], "no handler means nothing runs")
        XCTAssertFalse(
            event.objectForKeyedSubscript("defaultPrevented").toBool(),
            "an unclaimed Escape must not have its default prevented"
        )
        XCTAssertFalse(
            event.objectForKeyedSubscript("propagationStopped").toBool(),
            "an unclaimed Escape must still propagate"
        )
    }

    func testAnUnrelatedKeyIsLeftAlone() throws {
        bind(escape: true)
        let event = try XCTUnwrap(
            context.evaluateScript("press({ key: 'a', keyCode: 65 })")
        )
        assertNoThrow()
        XCTAssertEqual(log, [], "an ordinary character must reach the textarea")
        XCTAssertFalse(
            event.objectForKeyedSubscript("defaultPrevented").toBool(),
            "an ordinary character must not be claimed"
        )
    }
}
