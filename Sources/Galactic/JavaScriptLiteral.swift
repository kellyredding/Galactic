import Foundation

/// Encodes Swift values as JavaScript source, for the places a host has to
/// hand data to a page by building a call and evaluating it.
///
/// Hand-rolled escaping is the usual approach and it is reliably wrong: the
/// obvious two characters get handled and the rest do not. A value carrying an
/// apostrophe, a backslash in the wrong position, or a line terminator ends its
/// own string literal, and everything after it parses as bare syntax — so the
/// failure is a *syntax error in the whole injected snippet*, not a wrong value
/// in an otherwise working call. Nothing runs, and the only trace is a console
/// message inside a WebView.
///
/// Serialising instead of escaping removes the category. File paths are the
/// motivating case, because a filename can legally contain very nearly
/// anything.
public enum JavaScriptLiteral {

    /// A JavaScript array expression for `values`, safe to interpolate into
    /// source that will be evaluated.
    ///
    /// JSON is a subset of JavaScript expression syntax with one historical
    /// exception: U+2028 and U+2029 are legal unescaped inside a JSON string
    /// but terminated a string literal in JavaScript before ES2019. Current
    /// engines accept them, and they are escaped here anyway — the cost is two
    /// substitutions and it removes the last case where valid JSON is not
    /// valid JavaScript.
    public static func array(_ values: [String]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: values),
            let json = String(data: data, encoding: .utf8)
        else {
            // Unreachable for an array of strings. An empty array keeps the
            // call syntactically valid, so a caller degrades to doing nothing
            // rather than to injecting a broken script.
            return "[]"
        }
        return escapeLineSeparators(json)
    }

    /// A JavaScript string expression for `value`.
    public static func string(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [value]
            ),
            let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // Unwrap the single-element array back to its one element.
        let inner = json.dropFirst().dropLast()
        return escapeLineSeparators(String(inner))
    }

    private static func escapeLineSeparators(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
