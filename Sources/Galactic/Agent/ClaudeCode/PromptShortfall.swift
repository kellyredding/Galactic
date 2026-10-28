import Foundation

/// How much of a typed prompt failed to reach the agent.
public struct PromptShortfall: Equatable {
    public let sentCharacters: Int
    public let receivedCharacters: Int

    public init(sentCharacters: Int, receivedCharacters: Int) {
        self.sentCharacters = sentCharacters
        self.receivedCharacters = receivedCharacters
    }

    /// Nil when what arrived is whole. Compares non-whitespace characters
    /// after removing the wrappers Claude Code files a long paste in: the
    /// harness composes a trailing space and Claude Code trims its input.
    public static func measure(sent: String, received: String) -> PromptShortfall? {
        let sentCount = significantCount(sent)
        let receivedCount = significantCount(stripWrappers(received))
        let missing = sentCount - receivedCount
        guard missing > tolerance(for: sentCount) else { return nil }
        return PromptShortfall(
            sentCharacters: sentCount,
            receivedCharacters: receivedCount
        )
    }

    /// Losses seen are thousands of characters; this only absorbs small
    /// rewrites Claude Code may make to what it records.
    static func tolerance(for sentCount: Int) -> Int {
        max(16, sentCount / 100)
    }

    /// `<pasted_content id="…">` and its closing tag. A long prompt can be
    /// split across several, each carrying the same id.
    static func stripWrappers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?pasted_content\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func significantCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? count : count + 1
        }
    }
}
