import Foundation
import JavaScriptCore

/// A JavaScript source string that failed to parse.
struct JavaScriptSyntaxError: Error, CustomStringConvertible {
    /// The engine's own diagnostic, e.g. "SyntaxError: Unexpected end of
    /// script". Carries a line number when the engine supplies one.
    let message: String

    /// Caller-supplied name for the source, so a failure identifies which
    /// literal broke without the reader opening anything.
    let label: String

    var description: String { "\(label): \(message)" }
}

/// Parses JavaScript without running it.
///
/// This exists because a syntax error inside JavaScript that ships as a Swift
/// string literal compiles cleanly and only surfaces at runtime inside a
/// WebView, where it is at its most expensive to diagnose. Parsing at test time
/// turns that into a build failure.
///
/// Uses JavaScriptCore rather than shelling out to node, for three reasons that
/// each independently rule node out of a Swift package: there is no dependable
/// node on the `PATH` a package build sees, a build-tool plugin would run on
/// every consuming app's build rather than only the maintainer's, and node
/// would have to be handed the source parsed back out of Swift — reconstructing
/// the compiler's own unescaping in order to check it.
///
/// Checking `String` here instead means checking the exact bytes that ship. The
/// classic trap this closes: a regex written `/\n/g` inside a Swift multiline
/// literal reaches JavaScript as a real newline, which is not a valid regex. A
/// checker reading the source file sees two characters and shrugs; this one
/// sees what the engine will see.
enum JavaScriptSyntax {
    /// Returns `nil` when `source` parses, or the failure when it does not.
    ///
    /// Syntax only. Undefined references, bad logic, and anything that needs the
    /// script to actually run are out of scope — the point is to catch the class
    /// of error that would otherwise pass the build in silence.
    static func check(
        _ source: String, label: String
    ) -> JavaScriptSyntaxError? {
        guard let context = JSGlobalContextCreate(nil) else {
            return JavaScriptSyntaxError(
                message: "could not create a JavaScript context",
                label: label
            )
        }
        defer { JSGlobalContextRelease(context) }

        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }

        // Parses and discards. Nothing in `source` executes, so a literal is
        // safe to check no matter what it would do if it ran.
        var exception: JSValueRef?
        let parsed = JSCheckScriptSyntax(context, script, nil, 1, &exception)
        if parsed { return nil }

        return JavaScriptSyntaxError(
            message: Self.describe(exception, in: context),
            label: label
        )
    }

    /// Pull a readable diagnostic off the thrown value, falling back rather
    /// than trapping — a parse failure we cannot describe is still a parse
    /// failure, and reporting it vaguely beats reporting nothing.
    private static func describe(
        _ exception: JSValueRef?, in context: JSGlobalContextRef
    ) -> String {
        guard let exception else { return "did not parse" }
        guard let copied = JSValueToStringCopy(context, exception, nil) else {
            return "did not parse"
        }
        defer { JSStringRelease(copied) }
        guard let cf = JSStringCopyCFString(kCFAllocatorDefault, copied) else {
            return "did not parse"
        }
        let text = (cf as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "did not parse" : text
    }
}
