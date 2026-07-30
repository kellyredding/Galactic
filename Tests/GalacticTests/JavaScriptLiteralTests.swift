import JavaScriptCore
import XCTest
@testable import Galactic

/// Encoding values into JavaScript source that will be evaluated.
///
/// Every case here is a filename a user can legally create. The previous
/// approach escaped a backslash and an apostrophe and nothing else, so the
/// rest produced a snippet that failed to parse — which is worse than a wrong
/// value, because the whole injected script is discarded and nothing runs.
final class JavaScriptLiteralTests: XCTestCase {

    /// Names that have to survive a round trip into a page and back.
    private let hostileNames = [
        "/tmp/plain.png",
        "/tmp/it's mine.png",                 // apostrophe — closes the literal
        "/tmp/say \"hi\".png",                // double quote
        "/tmp/back\\slash.png",               // backslash
        "/tmp/trailing\\",                    // backslash at the end
        "/tmp/new\nline.png",                 // raw newline
        "/tmp/carriage\rreturn.png",
        "/tmp/tab\there.png",
        "/tmp/has:colon.png",
        "/tmp/line\u{2028}separator.png",     // legal JSON, historically not JS
        "/tmp/para\u{2029}separator.png",
        "/tmp/emoji ⚡️💯.png",
        "/tmp/</script><script>evil()</script>.png",
        "/tmp/quote'and\"both\\.png",
    ]

    /// Evaluates the encoded array through a real call and reads the values
    /// back — so this checks the payload *arrives intact*, not merely that it
    /// parses.
    private func roundTrip(_ values: [String]) throws -> [String] {
        let context = try XCTUnwrap(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }

        let snippet = """
        (function () {
            var received = null;
            function handleFileDrop(paths) { received = paths; }
            handleFileDrop(\(JavaScriptLiteral.array(values)));
            return received;
        })();
        """
        // The same shape the hosts inject: a call built by interpolation.
        if let failure = JavaScriptSyntax.check(snippet, label: "drop call") {
            XCTFail("encoded snippet does not parse: \(failure)")
        }
        let result = context.evaluateScript(snippet)
        if let thrown { XCTFail("evaluating threw: \(thrown)") }
        return result?.toArray() as? [String] ?? []
    }

    func testEveryHostileNameSurvivesIntact() throws {
        for name in hostileNames {
            let received = try roundTrip([name])
            XCTAssertEqual(
                received, [name], "mangled or dropped: \(name.debugDescription)"
            )
        }
    }

    func testAllNamesTogetherInOneCall() throws {
        XCTAssertEqual(try roundTrip(hostileNames), hostileNames)
    }

    func testEmptyArrayIsStillAValidCall() throws {
        XCTAssertEqual(try roundTrip([]), [])
        XCTAssertEqual(JavaScriptLiteral.array([]), "[]")
    }

    /// A closing script tag inside a filename must not be able to end the
    /// element it is injected into.
    func testScriptTagInAFilenameIsInert() throws {
        let name = "/tmp/</script><script>evil()</script>.png"
        let encoded = JavaScriptLiteral.array([name])
        XCTAssertFalse(
            encoded.contains("</script>"),
            "an unescaped closing tag would end the host <script> element"
        )
        XCTAssertEqual(try roundTrip([name]), [name])
    }

    func testStringEncodingMatchesArrayEncoding() throws {
        for name in hostileNames {
            let asString = JavaScriptLiteral.string(name)
            XCTAssertNil(JavaScriptSyntax.check("var x = \(asString);", label: name))
        }
    }
}
