import Foundation
import XCTest

@testable import Galactic

/// What a reader answers when it is asked about Escape.
///
/// The function these replace did the acting as well as the reporting, which
/// read as a convenience and behaved as a trap: two callers wanted the same
/// answer for different reasons, and only one of them wanted the page altered
/// on the way. Merely asking collapsed an open comment and cancelled an
/// unchanged edit — so the Back button, which asks in order to decide whether
/// to warn, mutated the page it was about to discard and could never warn
/// about a comment, because asking had already put it away.
///
/// A string-level suite, deliberately. These are shipped JavaScript literals
/// with no DOM to run them against here, and what is worth pinning is not the
/// behaviour of one branch but the property the whole change exists for: that
/// asking is free.
final class EscapeContextTests: XCTestCase {

    /// The body of a method in the annotation manager literal, by name.
    ///
    /// Crude on purpose — it slices from the declaration to the first
    /// same-indent close. Enough to tell what a function does and does not
    /// call, which is the only question here.
    private func body(of method: String) throws -> String {
        let js = annotationManagerJS
        let opening = "\(method)() {"
        let start = try XCTUnwrap(
            js.range(of: opening),
            "\(method) is not in the annotation manager"
        )
        let rest = js[start.upperBound...]
        let end = try XCTUnwrap(
            rest.range(of: "\n        },"),
            "\(method) has no same-indent close"
        )
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Asking is free

    /// The property the split exists for.
    func testAskingAboutEscapeChangesNothing() throws {
        let probe = try body(of: "escapeContext")
        for mutation in [
            "cancelEdit(",
            "collapse(",
            "collapseExpanded(",
            "dismissForm(",
            "dismissEmojiPopup(",
            ".value =",
            ".style.",
        ] {
            XCTAssertFalse(
                probe.contains(mutation),
                "escapeContext calls \(mutation) — asking is not free"
            )
        }
    }

    func testAskingWhatWouldBeLostChangesNothing() throws {
        let probe = try body(of: "unsavedTextKind")
        for mutation in ["cancelEdit(", "collapse(", "dismissForm("] {
            XCTAssertFalse(
                probe.contains(mutation),
                "unsavedTextKind calls \(mutation) — asking is not free"
            )
        }
    }

    /// The mutating original must be gone, not merely unused: a caller that
    /// found it would get the old behaviour with none of the warnings.
    func testTheMutatingProbeIsGone() {
        XCTAssertFalse(
            annotationManagerJS.contains("getEscapeContext"),
            "the mutating probe is still reachable"
        )
        XCTAssertFalse(
            annotationManagerJS.contains("__consumed__"),
            "a caller is still being told the page acted on its behalf"
        )
    }

    // MARK: - What each probe reports

    /// Escape unwinds one layer, so its answers name layers.
    func testEscapeContextNamesEveryLayer() throws {
        let probe = try body(of: "escapeContext")
        for layer in [
            "'emojiPopup'",
            "'overallComment'",
            "'editingDirty'",
            "'editingClean'",
            "'expanded'",
            "'formHasText'",
            "'formVisible'",
            "'close'",
        ] {
            XCTAssertTrue(
                probe.contains(layer),
                "escapeContext never reports \(layer)"
            )
        }
    }

    /// Back is leaving, so its answers name text rather than layers — and it
    /// has to see all three kinds. Reporting only the outermost is what let
    /// an open emoji popup carry Back past a half-written annotation.
    func testUnsavedTextKindNamesEveryKindOfText() throws {
        let probe = try body(of: "unsavedTextKind")
        for kind in ["'comment'", "'edit'", "'form'", "'none'"] {
            XCTAssertTrue(
                probe.contains(kind),
                "unsavedTextKind never reports \(kind)"
            )
        }
        // Layers are not text and must not appear here.
        for layer in ["'emojiPopup'", "'expanded'", "'formVisible'"] {
            XCTAssertFalse(
                probe.contains(layer),
                "unsavedTextKind reports \(layer), which loses no text"
            )
        }
    }

    /// The refresh gate stays narrower than Back's question: a rebuild
    /// carries the overall comment across, so warning about it there would
    /// be an alarm about something that no longer happens.
    func testTheRefreshGateIgnoresTheOverallComment() throws {
        let gate = try body(of: "hasOpenUnsavedComment")
        XCTAssertFalse(
            gate.contains("GalaxySendBar"),
            "the refresh gate would now warn about a comment it preserves"
        )
    }

    // MARK: - The actions the callers name

    func testEveryActionACallerNamesExists() {
        for action in [
            "dismissEmojiPopup()",
            "collapseOverallComment()",
            "cancelEdit(",
            "collapseExpanded(",
            "dismissForm(",
        ] {
            XCTAssertTrue(
                annotationManagerJS.contains(action),
                "a host names \(action) and the page cannot answer it"
            )
        }
    }

    /// Both hosts used to inline the emoji dismissal as a seven-line function
    /// literal, twice each. Single-sourcing it is the point of having it.
    func testDismissingTheEmojiPopupLooksAtBothComposers() throws {
        let action = try body(of: "dismissEmojiPopup")
        XCTAssertTrue(
            action.contains(".annotation-textarea:focus"),
            "the form composer's popup would be left open"
        )
        XCTAssertTrue(
            action.contains(".annotation-edit-textarea:focus"),
            "an edit composer's popup would be left open"
        )
    }

    /// The dirty check was written out twice, in the two probes, and is now
    /// asked once.
    func testTheDirtyEditCheckIsAskedRatherThanRepeated() throws {
        XCTAssertTrue(
            try body(of: "escapeContext").contains("editHasChanges()"),
            "escapeContext compares the edit itself"
        )
        XCTAssertTrue(
            try body(of: "unsavedTextKind").contains("editHasChanges()"),
            "unsavedTextKind compares the edit itself"
        )
    }
}
