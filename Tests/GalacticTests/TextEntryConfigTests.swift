import Foundation
import JavaScriptCore
import XCTest
@testable import Galactic

/// The one piece of JavaScript in a card document that is *generated* rather
/// than shipped, and therefore reaches no gate.
///
/// Both hosts build `window.GalaxyTextEntry.configure(<json>);` by serialising
/// the bindings payload and interpolating it into a call. Everything else in
/// those documents is a fixed literal checked at build time; this one is
/// assembled per render from user settings, so a keystroke whose label
/// serialised badly would produce a script that fails to parse — and a parse
/// failure takes down the whole `<script>` tag, not just the call.
final class TextEntryConfigTests: XCTestCase {

    private func configureCall(for bindings: TextEntryBindings) throws -> String {
        let data = try XCTUnwrap(
            try? JSONSerialization.data(withJSONObject: bindings.jsPayload)
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        return "window.GalaxyTextEntry.configure(\(json));"
    }

    func testShippedDefaultsProduceParsableJavaScript() throws {
        let call = try configureCall(for: .default)
        if let failure = JavaScriptSyntax.check(call, label: "textEntryConfig") {
            XCTFail("\(failure)\n\(call)")
        }
    }

    /// Every keystroke the key table can name, one at a time — the labels are
    /// where non-ASCII enters the payload (⌘, ⌥, ⌃, ⇧, arrows).
    func testEveryBindableKeystrokeProducesParsableJavaScript() throws {
        for (keyCode, _) in Keystroke.keyTable {
            for raw in 0...15 {
                let k = Keystroke(
                    keyCode: keyCode,
                    modifiers: Keystroke.Modifiers(rawValue: raw)
                )
                let call = try configureCall(
                    for: TextEntryBindings(submit: [k], newline: [])
                )
                if let failure = JavaScriptSyntax.check(
                    call, label: "keyCode \(keyCode) mods \(raw)"
                ) {
                    return XCTFail("\(failure)\n\(call)")
                }
            }
        }
    }

    /// Runs the generated call against the shipped matcher, so this covers the
    /// call being *accepted* and not merely parsing.
    func testGeneratedCallConfiguresTheShippedMatcher() throws {
        let context = try XCTUnwrap(JSContextForMatcher())
        context.evaluateScript(try configureCall(for: .default))
        let hint = context.evaluateScript(
            "window.GalaxyTextEntry.submitHint();"
        )?.toString()
        XCTAssertEqual(hint, "Enter")
    }

    private func JSContextForMatcher() -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.evaluateScript("var window = this;")
        context.evaluateScript(textEntryJS)
        return context
    }
}
