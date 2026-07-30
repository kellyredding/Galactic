import XCTest
@testable import Galactic

/// The card stylesheet serves two surfaces that name their elements
/// differently — `note-` in a terminal scrollback, `annotation-` in the
/// document readers — from one set of rules.
///
/// That substitution is the whole mechanism. If a selector ever stops carrying
/// the prefix it was handed, the rule silently stops matching on one surface
/// and nothing fails: the styling just quietly goes missing, on whichever
/// surface nobody happened to look at.
final class CardStylesTests: XCTestCase {

    private let prefixes = ["note", "annotation"]

    func testHostResetTargetsBothCardAndForm() {
        for prefix in prefixes {
            let css = hostResetCSS(prefix: prefix)
            XCTAssertTrue(css.contains(".\(prefix)-card"))
            XCTAssertTrue(css.contains(".\(prefix)-form"))
            // The descendant selectors are what actually neutralise the host's
            // element-name rules; without them the reset covers only the two
            // containers.
            XCTAssertTrue(css.contains(".\(prefix)-card *"))
            XCTAssertTrue(css.contains(".\(prefix)-form *"))
        }
    }

    func testDeleteConfirmTargetsTheArmedButton() {
        for prefix in prefixes {
            let css = deleteConfirmCSS(prefix: prefix)
            XCTAssertTrue(css.contains(".\(prefix)-btn-delete.confirming"))
            XCTAssertTrue(css.contains(".\(prefix)-btn-delete.confirming:hover"))
            XCTAssertTrue(css.contains(".\(prefix)-btn-delete.confirming::after"))
        }
    }

    /// The drain animation and the timer that disarms the button are written in
    /// two languages in two files and must agree. This pins the CSS half.
    func testDeleteConfirmDrainRunsForFiveSeconds() {
        let css = deleteConfirmCSS(prefix: "note")
        XCTAssertTrue(css.contains("animation: confirmDrain 5s linear forwards"))
        XCTAssertTrue(css.contains("@keyframes confirmDrain"))
    }

    func testSelectionToolbarAndIconButtonsCarryThePrefix() {
        for prefix in prefixes {
            XCTAssertTrue(
                selectionToolbarCSS(prefix: prefix)
                    .contains(".\(prefix)-form.selection-only")
            )
            let icons = iconButtonCSS(
                prefix: prefix, restColor: "#888", hoverColor: "#fff"
            )
            XCTAssertTrue(icons.contains(".\(prefix)-copy-lines"))
            XCTAssertTrue(icons.contains(".\(prefix)-suggest"))
            XCTAssertTrue(icons.contains(".\(prefix)-addnote"))
        }
    }

    /// No prefix here, deliberately: the popup is built by one shared
    /// autocomplete script rather than by either card manager, so both surfaces
    /// produce the same DOM. Parameterising it would be inventing a difference.
    func testEmojiPopupIsUnprefixedAndTakesItsColoursFromTheCaller() {
        let css = emojiPopupCSS(
            background: "SENTINEL_BG",
            border: "SENTINEL_BORDER",
            shadow: "SENTINEL_SHADOW"
        )
        XCTAssertTrue(css.contains(".emoji-popup {"))
        XCTAssertTrue(css.contains("background: SENTINEL_BG"))
        XCTAssertTrue(css.contains("border: 1px solid SENTINEL_BORDER"))
        XCTAssertTrue(css.contains("box-shadow: 0 4px 12px SENTINEL_SHADOW"))
        XCTAssertFalse(css.contains("note-"))
        XCTAssertFalse(css.contains("annotation-"))
    }

    /// Both surfaces resolve card text through one token, so composing and
    /// reading a note cannot differ in size.
    func testTokensCarryTheCallersTextSize() {
        XCTAssertTrue(
            noteUXTokens(textSize: "var(--font-size)")
                .contains("--note-text-size: var(--font-size)")
        )
        XCTAssertTrue(
            noteUXTokens(textSize: "13px").contains("--note-text-size: 13px")
        )
    }
}
