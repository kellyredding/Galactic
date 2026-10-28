import Foundation

/// Whether Claude Code has written a prompt into its session transcript since
/// this receipt was taken. Measured at 0.1–0.2s after the submit, queued
/// prompts included, however late its UserPromptSubmit hook runs.
public final class ClaudeTranscriptReceipt {
    private let find: () -> URL?
    private var transcript: URL?
    private let firstLine: String
    private let commandName: String?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var arrived = false

    /// What the transcript recorded for the prompt, once it has arrived.
    public private(set) var receivedText: String?

    /// For a session's transcript wherever Claude Code files it. A session's
    /// first prompt is what creates the file, so it is looked for again on
    /// each check until it appears.
    public convenience init(
        sessionId: String,
        prompt: String,
        projectsRoot: URL = ClaudeTranscriptReceipt.defaultProjectsRoot
    ) {
        self.init(prompt: prompt) {
            Self.locate(sessionId: sessionId, projectsRoot: projectsRoot)
        }
    }

    /// For a transcript at a known path, which need not exist yet.
    public convenience init(transcript: URL, prompt: String) {
        self.init(prompt: prompt) { transcript }
    }

    private init(prompt: String, find: @escaping () -> URL?) {
        self.find = find
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firstLine = Self.firstLine(of: trimmed)
        self.commandName = trimmed.hasPrefix("/")
            ? trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
            : nil
        // Everything already written predates the prompt. A transcript that
        // does not exist yet has nothing in it to skip.
        if let existing = find(),
            let size = (try? FileManager.default.attributesOfItem(
                atPath: existing.path)[.size] as? NSNumber)?.uint64Value
        {
            self.transcript = existing
            self.offset = size
        }
    }

    /// Whether a record carrying the prompt has been appended since the
    /// receipt was taken. Reads only what is new since the last call, and stays
    /// true once it is.
    public func hasArrived() -> Bool {
        guard !arrived, !firstLine.isEmpty else { return arrived }
        if transcript == nil { transcript = find() }
        guard let transcript,
            let handle = try? FileHandle(forReadingFrom: transcript)
        else {
            return false
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset {
            offset = 0
            partial.removeAll()
        }
        try? handle.seek(toOffset: offset)
        let fresh = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(fresh.count)
        partial.append(fresh)

        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let text = Self.promptText(inRecord: Data(line)), matches(text) {
                arrived = true
                receivedText = text
                return true
            }
        }
        return false
    }

    /// How much of `sent` the transcript is missing, or nil when the prompt
    /// arrived whole or has not arrived yet.
    public func shortfall(of sent: String) -> PromptShortfall? {
        guard let receivedText else { return nil }
        return PromptShortfall.measure(sent: sent, received: receivedText)
    }

    public static let defaultProjectsRoot = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// The transcript for a session, wherever Claude Code filed it.
    ///
    /// Found by name rather than computed, because the project folder is an
    /// escaped form of the directory the session was launched from, and that
    /// escaping is Claude Code's to change.
    public static func locate(
        sessionId: String,
        projectsRoot: URL = defaultProjectsRoot
    ) -> URL? {
        let name = sessionId.lowercased() + ".jsonl"
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Matching

    func matches(_ recordText: String) -> Bool {
        var text = recordText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = commandName,
            text.contains("<command-name>\(name)</command-name>")
        {
            return true
        }
        // A long typed prompt is filed inside a wrapper of Claude Code's own.
        if text.hasPrefix("<pasted_content"),
            let close = text.firstIndex(of: ">")
        {
            text = String(text[text.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.hasPrefix(firstLine)
    }

    /// The prompt a transcript record carries, or nil when it carries none: a
    /// user prompt, or a prompt queued while a turn was running. Tool results
    /// and every other record type are not prompts.
    static func promptText(inRecord line: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let record = object as? [String: Any],
            let type = record["type"] as? String
        else { return nil }

        switch type {
        case "queue-operation":
            guard record["operation"] as? String == "enqueue" else { return nil }
            return record["content"] as? String
        case "user":
            let content = (record["message"] as? [String: Any])?["content"]
            if let text = content as? String { return text }
            guard let blocks = content as? [[String: Any]],
                !blocks.contains(where: { $0["type"] as? String == "tool_result" })
            else { return nil }
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
