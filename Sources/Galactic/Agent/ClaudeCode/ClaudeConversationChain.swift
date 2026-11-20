import Foundation

/// The transcripts a conversation has continued into.
///
/// Claude Code continues a conversation in a new transcript when it is resumed
/// while another process still holds it, recording the move as a
/// `continued-in` record in the old one. Resuming the old id afterwards reopens
/// the conversation as it stood before the move.
public enum ClaudeConversationChain {

    /// From `sessionId` to the newest conversation it continued into, oldest
    /// first. An id whose transcript is missing from `directory` ends the chain,
    /// since there is nothing there to resume.
    public static func resolve(sessionId: String, in directory: URL) -> [String] {
        var chain = [sessionId]
        var seen: Set<String> = [sessionId.lowercased()]
        var current = sessionId
        while let next = continuation(of: transcript(current, in: directory)) {
            guard seen.insert(next.lowercased()).inserted,
                FileManager.default.fileExists(atPath: transcript(next, in: directory).path)
            else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    /// The target of the last `continued-in` record in a transcript.
    static func continuation(of transcript: URL) -> String? {
        guard let data = try? Data(contentsOf: transcript, options: .mappedIfSafe) else {
            return nil
        }
        let marker = Data("\"continued-in\"".utf8)
        var last: String?
        var from = data.startIndex
        while from < data.endIndex,
            let hit = data.range(of: marker, in: from..<data.endIndex)
        {
            let start = data[..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 }
                ?? data.startIndex
            let end = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let target = target(inRecord: data[start..<end]) { last = target }
            from = end
        }
        return last
    }

    /// The marker also appears in message text that quotes it, so only a
    /// record whose own type is `continued-in` counts.
    static func target(inRecord line: Data) -> String? {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            record["type"] as? String == "continued-in",
            let id = record["continuedInSessionId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    private static func transcript(_ sessionId: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(sessionId).jsonl")
    }
}
