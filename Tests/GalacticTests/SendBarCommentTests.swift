import Foundation
import JavaScriptCore
import XCTest

@testable import Galactic

/// The send bar's overall comment: a composer that opens on the first press of
/// the bar and sends on the second.
///
/// Two things here are worth pinning rather than reading. The first is that the
/// step is opt-in — a host that never asks for a comment must still send on one
/// press, because one of the two surfaces that shows this bar lives in an app
/// this package cannot see. The second is the count gate, which moved into
/// `fire` from the hosts: the scrollback tested its note count at its own
/// keydown and the readers tested nothing, so the chord fired into a reader with
/// nothing pending and closed it.
final class SendBarCommentTests: XCTestCase {

    private var context: JSContext!
    private var thrown: String?

    override func setUpWithError() throws {
        let context = try XCTUnwrap(JSContext())
        thrown = nil
        context.exceptionHandler = { [weak self] _, exception in
            self?.thrown = exception?.toString() ?? "unknown JS exception"
        }

        context.evaluateScript("var window = this;")

        // A DOM stand-in carrying only what the bar touches: five elements by
        // id, a body with a style, and enough of an element to be appended to,
        // focused, and listened on.
        context.evaluateScript(
            """
            var log = [];
            var emojiClaims = false;
            var EmojiAutocomplete = {
                handleKeyDown: function () { return emojiClaims; }
            };
            var els = {};
            function makeEl(id) {
                return {
                    id: id,
                    className: '',
                    value: '',
                    placeholder: '',
                    rows: 0,
                    textContent: '',
                    disabled: false,
                    selectionStart: 0,
                    selectionEnd: 0,
                    offsetHeight: 40,
                    dataset: {},
                    style: {},
                    children: [],
                    _listeners: {},
                    _attrs: {},
                    addEventListener: function (t, fn) {
                        this._listeners[t] = fn;
                    },
                    setAttribute: function (k, v) { this._attrs[k] = v; },
                    removeAttribute: function (k) { delete this._attrs[k]; },
                    appendChild: function (c) {
                        this.children.push(c);
                        els[c.id] = c;
                    },
                    focus: function () { log.push('focus:' + this.id); },
                    setSelectionRange: function (s, e) {
                        this.selectionStart = s; this.selectionEnd = e;
                    },
                    dispatchEvent: function () {},
                    querySelector: function () { return null; }
                };
            }
            ['send-bar', 'send-bar-count', 'send-bar-button',
             'send-bar-comment'].forEach(function (id) {
                els[id] = makeEl(id);
            });
            els['send-bar'].style.display = 'none';
            els['send-bar-comment'].style.display = 'none';

            var document = {
                body: { style: {} },
                getElementById: function (id) { return els[id] || null; },
                createElement: function () { return makeEl(''); }
            };

            function pressOn(id, init) {
                var el = els[id];
                var e = {
                    key: init.key,
                    code: init.code || '',
                    keyCode: init.keyCode || 0,
                    metaKey: !!init.metaKey,
                    ctrlKey: !!init.ctrlKey,
                    altKey: !!init.altKey,
                    shiftKey: !!init.shiftKey,
                    defaultPrevented: false,
                    preventDefault: function () {
                        this.defaultPrevented = true;
                    },
                    stopPropagation: function () {}
                };
                el._listeners['keydown'](e);
                return e;
            }
            """
        )

        context.evaluateScript(textEntryJS)
        context.evaluateScript(cardTextJS)
        context.evaluateScript(sendBarJS)

        // The shipped defaults, fixed here so the assertions are about the
        // wiring rather than about whatever the default happens to be.
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

    /// Opt into the comment and record what `invoke` is handed.
    private func configureWithComment() {
        context.evaluateScript(
            """
            window.GalaxySendBar.configure({
                noun: 'note',
                comment: true,
                invoke: function (c) { log.push('invoke:' + c); }
            });
            """
        )
    }

    private func configureWithoutComment() {
        context.evaluateScript(
            """
            window.GalaxySendBar.configure({
                noun: 'note',
                invoke: function (c) { log.push('invoke:' + c); }
            });
            """
        )
    }

    private func log() -> [String] {
        context.evaluateScript("log")?.toArray() as? [String] ?? []
    }

    private func bool(_ expression: String) -> Bool {
        context.evaluateScript(expression)?.toBool() ?? false
    }

    private func string(_ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    // MARK: - The count gate

    func testFireWithNothingToSendDoesNothing() {
        configureWithComment()
        context.evaluateScript("window.GalaxySendBar.fire();")
        XCTAssertEqual(log(), [])
        XCTAssertFalse(bool("window.GalaxySendBar.expanded"))
        assertNoThrow()
    }

    func testUpdateRecordsTheCountItIsGiven() {
        configureWithComment()
        context.evaluateScript("window.GalaxySendBar.update(2);")
        XCTAssertEqual(
            string("String(window.GalaxySendBar.count)"), "2"
        )
        XCTAssertEqual(
            string("els['send-bar-count'].textContent"), "2 notes"
        )
        XCTAssertEqual(string("els['send-bar'].style.display"), "flex")
        assertNoThrow()
    }

    // MARK: - The two steps

    func testFirstPressOpensAndFocusesWithoutSending() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertTrue(bool("window.GalaxySendBar.expanded"))
        XCTAssertEqual(log(), ["focus:send-bar-comment-input"])
        XCTAssertEqual(
            string("els['send-bar-comment'].style.display"), ""
        )
        assertNoThrow()
    }

    func testSecondPressSendsWhatWasTyped() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            els['send-bar-comment-input'].value = 'looks good overall';
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertEqual(
            log(),
            ["focus:send-bar-comment-input", "invoke:looks good overall"]
        )
        assertNoThrow()
    }

    func testAnEmptyCommentStillSends() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertEqual(
            log(), ["focus:send-bar-comment-input", "invoke:"]
        )
        assertNoThrow()
    }

    /// The whole reason the step is a config key: the scrollback in the other
    /// app reaches this same bar, and a host that has not asked for a comment
    /// must be unable to tell this exists.
    func testAHostThatDidNotAskSendsOnTheFirstPress() {
        configureWithoutComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertEqual(log(), ["invoke:"])
        XCTAssertFalse(bool("window.GalaxySendBar.expanded"))
        assertNoThrow()
    }

    // MARK: - Keys inside the composer

    func testTheConfiguredSubmitKeySends() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            els['send-bar-comment-input'].value = 'ship it';
            pressOn('send-bar-comment-input', {
                key: 'Enter', code: 'Enter'
            });
            """
        )
        XCTAssertEqual(
            log(), ["focus:send-bar-comment-input", "invoke:ship it"]
        )
        assertNoThrow()
    }

    func testTheConfiguredNewlineKeyDoesNotSend() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            els['send-bar-comment-input'].value = 'first line';
            pressOn('send-bar-comment-input', {
                key: 'Enter', code: 'Enter', altKey: true
            });
            """
        )
        XCTAssertEqual(log(), ["focus:send-bar-comment-input"])
        assertNoThrow()
    }

    /// The chord has to be answered on the textarea, because the document-level
    /// handler that normally answers it stands aside for textareas on purpose.
    func testTheSendChordSendsFromInsideTheComposer() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            els['send-bar-comment-input'].value = 'via the chord';
            var e = pressOn('send-bar-comment-input', {
                key: 'Enter', code: 'Enter',
                metaKey: true, shiftKey: true
            });
            var prevented = e.defaultPrevented;
            """
        )
        XCTAssertEqual(
            log(),
            ["focus:send-bar-comment-input", "invoke:via the chord"]
        )
        XCTAssertTrue(bool("prevented"))
        assertNoThrow()
    }

    func testAnOpenEmojiPopupClaimsTheChordFirst() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            emojiClaims = true;
            pressOn('send-bar-comment-input', {
                key: 'Enter', code: 'Enter',
                metaKey: true, shiftKey: true
            });
            """
        )
        XCTAssertEqual(log(), ["focus:send-bar-comment-input"])
        assertNoThrow()
    }

    // MARK: - Escape

    func testEscapeCollapsesAndKeepsTheText() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            els['send-bar-comment-input'].value = 'half a thought';
            pressOn('send-bar-comment-input', { key: 'Escape' });
            var collapsedDisplay = els['send-bar-comment'].style.display;
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertEqual(string("collapsedDisplay"), "none")
        XCTAssertTrue(bool("window.GalaxySendBar.expanded"))
        XCTAssertEqual(
            string("window.GalaxySendBar.commentText()"), "half a thought"
        )
        // Reopened, not sent: two focuses and no invoke.
        XCTAssertEqual(
            log(),
            [
                "focus:send-bar-comment-input",
                "focus:send-bar-comment-input",
            ]
        )
        assertNoThrow()
    }

    // MARK: - The gutter the bar owes the body

    func testTheBodyGutterTracksTheBar() {
        configureWithComment()
        context.evaluateScript("window.GalaxySendBar.update(1);")
        XCTAssertEqual(
            string("document.body.style.paddingBottom"), "48px"
        )
        // A taller bar owes a taller gutter.
        context.evaluateScript(
            """
            els['send-bar'].offsetHeight = 96;
            window.GalaxySendBar.fire();
            """
        )
        XCTAssertEqual(
            string("document.body.style.paddingBottom"), "104px"
        )
        assertNoThrow()
    }

    func testAHiddenBarReturnsTheGutterToTheStylesheet() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            window.GalaxySendBar.update(0);
            """
        )
        XCTAssertEqual(string("document.body.style.paddingBottom"), "")
        XCTAssertFalse(bool("window.GalaxySendBar.expanded"))
        XCTAssertEqual(string("els['send-bar'].style.display"), "none")
        assertNoThrow()
    }

    // MARK: - Authoring

    func testTheComposerIsBuiltOnceAndCarriesTheSubmitHint() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            var first = els['send-bar-comment-input'];
            window.GalaxySendBar.collapse();
            window.GalaxySendBar.fire();
            var same = first === els['send-bar-comment-input'];
            var childCount = els['send-bar-comment'].children.length;
            """
        )
        XCTAssertTrue(bool("same"))
        XCTAssertEqual(string("String(childCount)"), "1")
        XCTAssertEqual(
            string("els['send-bar-comment-input'].className"),
            "send-bar-comment-input"
        )
        // Derived from the live binding rather than asserted in copy.
        XCTAssertTrue(
            string("els['send-bar-comment-input'].placeholder")
                .contains("to send")
        )
        assertNoThrow()
    }

    func testTheComposerSwitchesOffTheSameThingsEveryOtherOneDoes() {
        configureWithComment()
        context.evaluateScript(
            """
            window.GalaxySendBar.update(1);
            window.GalaxySendBar.fire();
            var attrs = els['send-bar-comment-input']._attrs;
            """
        )
        for name in ["spellcheck", "autocorrect", "autocapitalize", "autocomplete"] {
            XCTAssertFalse(
                string("String(attrs['\(name)'])") == "undefined",
                "the comment composer did not switch off \(name)"
            )
        }
        assertNoThrow()
    }
}
