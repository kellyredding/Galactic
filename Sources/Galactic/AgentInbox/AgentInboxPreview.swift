import Foundation

/// How a queued message reads in a collapsed inbox row, and whether collapsing
/// it hid anything.
///
/// Separate from the row because the answer decides whether an expand
/// affordance appears at all, and it is wrong in two different ways: a message
/// past the cap, and one whose line breaks the preview flattens away. A row
/// that showed the affordance only for the first would silently offer nothing
/// to a short, structured message — which is most automated task prompts.
enum AgentInboxPreview {
    /// Long enough to tell two queued prompts apart, short enough that a row
    /// stays a row. Paired with the view's own line limit: this bounds the
    /// string, that bounds the space it may occupy.
    static let characterCap = 220

    /// The message as stored, minus the blank space around it.
    static func full(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a collapsed row shows: one run-on line, capped.
    ///
    /// Line breaks become spaces rather than being kept, because three lines of
    /// a structured prompt are usually its preamble — flattening spends the
    /// same space on the part that differs between two of them.
    static func collapsed(_ body: String) -> String {
        let flattened = full(body)
            .replacingOccurrences(of: "\n", with: " ")
        return flattened.count > characterCap
            ? String(flattened.prefix(characterCap)) + "…"
            : flattened
    }

    /// Whether collapsing hid anything, and so whether to offer an expansion.
    ///
    /// Asked of the two strings rather than of the body's length, so it stays
    /// true to whatever `collapsed` does. It cannot see the view's line limit
    /// clipping a short message in a narrow window — detecting that needs a
    /// measurement the rest of this app does without.
    static func isTruncated(_ body: String) -> Bool {
        collapsed(body) != full(body)
    }
}
