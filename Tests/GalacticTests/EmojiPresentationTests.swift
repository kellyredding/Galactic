import JavaScriptCore
import XCTest
@testable import Galactic

/// Emoji inserted into a composer must render as colour emoji, not as the
/// monochrome text glyph a monospace font may happen to supply.
///
/// Composers render in a monospace stack, and 64 of the 1,913 emoji in the
/// dataset are a single BMP character old enough to predate emoji — ⚡, ⭐, ✅,
/// the zodiac. Menlo and its relatives carry text glyphs for those, and font
/// fallback resolves per glyph in stack order, so the text font wins over the
/// emoji font regardless of the character's documented default presentation.
/// The result was ⚡ arriving as a thin grey bolt beside a full-colour 💯 —
/// which lives outside the BMP, is in no text font, and therefore fell through
/// to the emoji font.
///
/// Appending U+FE0F makes the text font's glyph ineligible. These tests pin
/// both halves: that it is applied where it is needed, and — more importantly —
/// that it is *not* applied where it would corrupt a sequence.
final class EmojiPresentationTests: XCTestCase {

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

    private func present(_ context: JSContext, _ emoji: String) -> String? {
        let escaped = emoji.unicodeScalars
            .map { String(format: "\\u{%X}", $0.value) }
            .joined()
        return context.evaluateScript(
            "__EA.emojiPresentation('\(escaped)');"
        )?.toString()
    }

    private func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    func testAddsSelectorToLoneBMPEmoji() throws {
        let context = try makeContext()
        // ⚡ U+26A1 — the reported case.
        let zap = try XCTUnwrap(present(context, "\u{26A1}"))
        XCTAssertEqual(scalars(zap), [0x26A1, 0xFE0F])

        // ⭐ and ✅ are the same shape of problem.
        XCTAssertEqual(
            scalars(try XCTUnwrap(present(context, "\u{2B50}"))),
            [0x2B50, 0xFE0F]
        )
        XCTAssertEqual(
            scalars(try XCTUnwrap(present(context, "\u{2705}"))),
            [0x2705, 0xFE0F]
        )
    }

    func testLeavesNonBMPEmojiAlone() throws {
        let context = try makeContext()
        // 💯 U+1F4AF already renders from the emoji font: no text font has it.
        XCTAssertEqual(
            scalars(try XCTUnwrap(present(context, "\u{1F4AF}"))), [0x1F4AF]
        )
    }

    func testDoesNotDoubleUpAnExistingSelector() throws {
        let context = try makeContext()
        // ⚠️ already carries U+FE0F in the dataset.
        XCTAssertEqual(
            scalars(try XCTUnwrap(present(context, "\u{26A0}\u{FE0F}"))),
            [0x26A0, 0xFE0F]
        )
    }

    /// The case that would do real damage. A flag is two regional indicators
    /// and a selector appended to it is not a flag any more.
    func testLeavesMultiScalarSequencesIntact() throws {
        let context = try makeContext()
        let flag = try XCTUnwrap(present(context, "\u{1F1FA}\u{1F1F8}"))
        XCTAssertEqual(scalars(flag), [0x1F1FA, 0x1F1F8])

        // Skin-tone modifier.
        let thumb = try XCTUnwrap(present(context, "\u{1F44D}\u{1F3FD}"))
        XCTAssertEqual(scalars(thumb), [0x1F44D, 0x1F3FD])
    }

    /// Guards the blast radius. If this count moves, the rule changed shape and
    /// someone should say why.
    func testExactlyTheKnownSetIsAffected() throws {
        let context = try makeContext()
        let changed = context.evaluateScript(
            """
            (function () {
                var n = 0;
                for (var k in EMOJI_DATA.map) {
                    var raw = EMOJI_DATA.map[k];
                    if (__EA.emojiPresentation(raw) !== raw) n++;
                }
                return n;
            })();
            """
        )?.toInt32()
        XCTAssertEqual(changed, 64)
    }
}
