import JavaScriptCore
import XCTest
@testable import Galactic

/// When a colon opens an emoji shortcode.
///
/// The autocomplete must not appear inside text that merely contains a colon —
/// a time, a URL, a key/value pair — because a suggestion list there is noise
/// over something the user is not writing. The original rule achieved that by
/// demanding whitespace before the colon, which also refused a shortcode typed
/// straight after an emoji with nothing between them.
///
/// The rule is now the absence of a word character, so both halves are worth
/// pinning: the cases that must fire, and the cases that must stay silent.
final class EmojiTriggerTests: XCTestCase {

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.evaluateScript("var window = this;")
        context.evaluateScript(EmojiJS.data)
        context.evaluateScript(EmojiJS.autocomplete)
        context.evaluateScript("var __EA = EmojiAutocomplete;")
        if let thrown { XCTFail("loading emoji scripts threw: \(thrown)") }
        return context
    }

    /// `detectTrigger` reads only `value` and `selectionEnd`, so a plain object
    /// stands in for the textarea and the whole rule is testable without a DOM.
    private func query(_ context: JSContext, _ text: String) -> String? {
        let escaped = text.unicodeScalars
            .map { String(format: "\\u{%X}", $0.value) }
            .joined()
        let result = context.evaluateScript(
            """
            (function () {
                var t = __EA.detectTrigger({
                    value: '\(escaped)',
                    selectionEnd: Array.from('\(escaped)').length
                        + '\(escaped)'.length - Array.from('\(escaped)').length
                });
                return t ? t.query : null;
            })();
            """
        )
        guard let result, !result.isNull, !result.isUndefined else { return nil }
        return result.toString()
    }

    func testFiresAtTheStartOfTheText() throws {
        XCTAssertEqual(query(try makeContext(), ":100"), "100")
    }

    func testFiresAfterWhitespace() throws {
        XCTAssertEqual(query(try makeContext(), "hello :100"), "100")
    }

    /// The reported case: a second shortcode typed straight after the emoji the
    /// first one inserted, with nothing between them.
    func testFiresAfterAnEmoji() throws {
        let context = try makeContext()
        // With the variation selector the insertion now appends.
        XCTAssertEqual(query(context, "\u{26A1}\u{FE0F}:100"), "100")
        // And a non-BMP emoji, where the preceding unit is a surrogate.
        XCTAssertEqual(query(context, "\u{1F4AF}:100"), "100")
    }

    func testFiresAfterPunctuation() throws {
        let context = try makeContext()
        XCTAssertEqual(query(context, "(:100"), "100")
        XCTAssertEqual(query(context, "\u{2014}:100"), "100")
    }

    // MARK: - Must stay silent

    func testDoesNotFireInsideATime() throws {
        XCTAssertNil(query(try makeContext(), "10:30"))
    }

    func testDoesNotFireInsideAURL() throws {
        XCTAssertNil(query(try makeContext(), "http://example"))
    }

    func testDoesNotFireInsideAKeyValuePair() throws {
        XCTAssertNil(query(try makeContext(), "key:value"))
    }

    /// Letters in any script, not only ASCII — the previous rule was
    /// whitespace-based and never had to think about this.
    func testDoesNotFireAfterNonASCIILetters() throws {
        let context = try makeContext()
        XCTAssertNil(query(context, "caf\u{E9}:100"))
        XCTAssertNil(query(context, "\u{65E5}:100"))
    }

    func testDoesNotFireAfterADigitOrUnderscore() throws {
        let context = try makeContext()
        XCTAssertNil(query(context, "abc9:100"))
        XCTAssertNil(query(context, "foo_:100"))
    }
}
