import XCTest
@testable import Galactic

/// Tests the JavaScript syntax checker itself.
///
/// Until embedded literals move into this package there is nothing else for it
/// to check, and a gate that has only ever been shown to accept is not a gate.
/// Every case below that expects a failure is the load-bearing half.
final class JavaScriptSyntaxTests: XCTestCase {

    // MARK: - Accepts

    func testAcceptsAnImmediatelyInvokedFunction() {
        // The shape every shipped literal uses.
        let js = """
        (function() {
            if (window.Thing) return;
            function helper(x) { return x + 1; }
            window.Thing = { helper: helper };
        })();
        """
        XCTAssertNil(JavaScriptSyntax.check(js, label: "iife"))
    }

    func testAcceptsAnEmptySource() {
        XCTAssertNil(JavaScriptSyntax.check("", label: "empty"))
    }

    func testAcceptsAWellFormedRegularExpression() {
        // The escaped form: written `\\n` in Swift, so JavaScript receives the
        // two characters backslash-n and the regex is valid.
        let js = #"var cleaned = text.replace(/\n/g, ' ');"#
        XCTAssertNil(JavaScriptSyntax.check(js, label: "regex"))
    }

    // MARK: - Rejects

    func testRejectsAMissingBrace() {
        let js = """
        (function() {
            if (true) { return 1;
        })();
        """
        XCTAssertNotNil(JavaScriptSyntax.check(js, label: "missing-brace"))
    }

    func testRejectsAnUnterminatedStringLiteral() {
        let js = "var greeting = 'hello;"
        XCTAssertNotNil(JavaScriptSyntax.check(js, label: "unterminated"))
    }

    /// The trap that motivates checking the compiled string rather than the
    /// Swift source.
    ///
    /// A regex written `/\n/g` in a Swift multiline literal is not two
    /// characters by the time it ships — the compiler turns it into a real
    /// newline, and a regex literal cannot span lines. A checker reading the
    /// `.swift` file sees a backslash and an `n` and passes it; this one sees
    /// what the engine sees.
    func testRejectsARegexBrokenByARawNewline() {
        let js = "var cleaned = text.replace(/\n/g, ' ');"
        XCTAssertNotNil(
            JavaScriptSyntax.check(js, label: "raw-newline-regex"),
            "a raw newline inside a regex literal must not parse"
        )
    }

    func testRejectsAStrayClosingParenthesis() {
        XCTAssertNotNil(
            JavaScriptSyntax.check("var x = (1 + 2));", label: "stray-paren")
        )
    }

    // MARK: - Diagnostics

    func testFailureCarriesTheLabelAndAMessage() {
        guard let failure = JavaScriptSyntax.check(
            "var x = (1 + 2));", label: "some-literal"
        ) else {
            return XCTFail("expected a syntax failure")
        }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(failure.label, "some-literal")
        // The description is what a failing gate prints, so it has to name the
        // literal — a wall of parse errors with no source attached is not
        // actionable.
        XCTAssertTrue(failure.description.contains("some-literal"))
    }

    func testSyntaxCheckDoesNotExecuteTheSource() {
        // If `check` evaluated instead of parsing, this would throw at runtime
        // and could not be reported as a *syntax* result. It parses fine.
        let js = "definitelyNotDefined.callMe();"
        XCTAssertNil(JavaScriptSyntax.check(js, label: "not-executed"))
    }
}
