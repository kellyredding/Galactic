import XCTest
@testable import Galactic

/// Every piece of JavaScript this package ships, parsed.
///
/// The consuming apps run a gate over their own source trees for exactly this
/// reason: JavaScript inside a Swift string literal is opaque to the compiler,
/// so a syntax error in one builds clean and fails only at runtime inside a
/// WebView. Those gates walk each app's own directory and cannot see in here.
///
/// This is the other half of that arrangement. Anything that moves into this
/// package stops being covered there and has to start being covered here, in
/// the same change — the apps' gates enforce their side by failing when their
/// literal count drops, and this is what makes lowering that count honest.
///
/// **Add an entry here whenever a JavaScript-bearing value moves in.** A gate
/// that silently stops covering something is worse than no gate, because it
/// still reports success.
final class ShippedJavaScriptTests: XCTestCase {

    /// Name → source, for everything shipped as an embedded literal.
    private var embeddedLiterals: [(String, String)] {
        [
            ("textEntryJS", textEntryJS),
            ("clipboardCopyJS", clipboardCopyJS),
            ("suggestionInsertJS", suggestionInsertJS),
            ("addNoteButtonJS", addNoteButtonJS),
            ("cardTextJS", cardTextJS),
            ("sendBarJS", sendBarJS),
            ("GalaxyFindJS.userScriptSource", GalaxyFindJS.userScriptSource),
            (
                "ScrollbackHTMLRenderer.scrollbackManagerJS",
                ScrollbackHTMLRenderer.scrollbackManagerJS
            ),
            (
                "ScrollbackHTMLRenderer.noteManagerJS",
                ScrollbackHTMLRenderer.noteManagerJS
            ),
            ("annotationManagerJS", annotationManagerJS),
            (
                "HTMLEscape.javaScriptFunction",
                HTMLEscape.javaScriptFunction
            ),
            (
                "HTMLRenderer.blockIndexDOMWalkJS",
                HTMLRenderer.blockIndexDOMWalkJS
            ),
            ("SourceRenderer.highlightJS", SourceRenderer.highlightJS),
            // Built per call rather than stored, so it is registered with a
            // line and an anchoring filled in — which is the only form of it
            // that is ever evaluated, and the only form that is JavaScript.
            (
                "ReaderLineJump.javaScript",
                ReaderLineJump.javaScript(
                    line: 1, anchoring: SourceRenderer.anchoring
                )
            ),
        ]
    }

    /// Name → source, for everything shipped as a bundled resource.
    private var bundledResources: [(String, String)] {
        [
            ("emoji-data.js", EmojiJS.data),
            ("emoji-autocomplete.js", EmojiJS.autocomplete),
        ]
    }

    func testEveryEmbeddedLiteralParses() {
        for (name, source) in embeddedLiterals {
            XCTAssertFalse(
                source.isEmpty, "\(name) is empty — did it lose its contents?"
            )
            if let failure = JavaScriptSyntax.check(source, label: name) {
                XCTFail("\(failure)")
            }
        }
    }

    func testEveryBundledResourceParses() {
        for (name, source) in bundledResources {
            // Empty means the resource did not make it into the bundle — the
            // accessor degrades to "" rather than trapping, so without this
            // the syntax check below would pass on nothing at all.
            XCTAssertFalse(
                source.isEmpty,
                "\(name) is missing from the package bundle — check the "
                    + "resources declaration in Package.swift"
            )
            if let failure = JavaScriptSyntax.check(source, label: name) {
                XCTFail("\(failure)")
            }
        }
    }

    /// Coverage floor, mirroring the one each app's gate carries.
    ///
    /// The lists above are hand-maintained, so the failure mode is forgetting
    /// to add an entry rather than an entry going stale. This will not catch
    /// that on its own — but paired with the apps' floors, a literal cannot
    /// leave an app without someone being told, and this is where it has to
    /// arrive.
    func testCoverageHasNotShrunk() {
        XCTAssertGreaterThanOrEqual(embeddedLiterals.count, 13)
        XCTAssertGreaterThanOrEqual(bundledResources.count, 2)
    }
}
