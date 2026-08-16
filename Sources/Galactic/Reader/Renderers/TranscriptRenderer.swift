import Foundation

/// Renders an agent transcript as a structured conversation.
///
/// Block indices are assigned as the document is built rather than walked for
/// afterwards, because the structure is known here and guessing it back from
/// the rendered markup would be strictly worse.
public enum TranscriptRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.blocks(selector: ".transcript-step")

    // MARK: - JSONL Parsing

    /// A single parsed entry from the JSONL transcript.
    enum TranscriptEntry {
        /// Initial user prompt text
        case userText(String)
        /// Tool result content
        case toolResult(
            toolUseId: String,
            content: String
        )
        /// Assistant reasoning text
        case assistantText(String)
        /// Assistant tool call
        case toolUse(
            id: String,
            name: String,
            detail: String
        )
    }

    /// Parsed transcript with entries and stats.
    struct ParsedTranscript {
        let entries: [TranscriptEntry]
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let agentId: String?
        let messageCount: Int
    }

    /// Parse JSONL content into transcript entries.
    static func parseTranscript(
        _ content: String
    ) -> ParsedTranscript {
        var entries: [TranscriptEntry] = []
        var totalInput = 0
        var totalOutput = 0
        var agentId: String? = nil
        var messageCount = 0

        for line in content.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization
                      .jsonObject(with: data)
                      as? [String: Any],
                  let message = obj["message"]
                      as? [String: Any]
            else { continue }

            messageCount += 1

            if agentId == nil {
                agentId = obj["agentId"] as? String
            }

            if let usage = message["usage"]
                as? [String: Any]
            {
                if let input = usage["input_tokens"]
                    as? Int
                {
                    totalInput += input
                }
                if let cacheRead = usage[
                    "cache_read_input_tokens"
                ] as? Int {
                    totalInput += cacheRead
                }
                if let cacheCreate = usage[
                    "cache_creation_input_tokens"
                ] as? Int {
                    totalInput += cacheCreate
                }
                if let output = usage["output_tokens"]
                    as? Int
                {
                    totalOutput += output
                }
            }

            let type = obj["type"] as? String ?? ""
            let msgContent = message["content"]

            if type == "user" {
                if let text = msgContent as? String {
                    entries.append(.userText(text))
                } else if let parts = msgContent
                    as? [[String: Any]]
                {
                    for part in parts {
                        let partType = part["type"]
                            as? String ?? ""
                        if partType == "tool_result" {
                            let toolUseId =
                                part["tool_use_id"]
                                    as? String ?? ""
                            let resultContent: String
                            if let text = part["content"]
                                as? String
                            {
                                resultContent = text
                            } else if let nested =
                                part["content"]
                                    as? [[String: Any]]
                            {
                                resultContent = nested
                                    .compactMap {
                                        $0["text"]
                                            as? String
                                    }
                                    .joined(
                                        separator: "\n"
                                    )
                            } else {
                                resultContent = ""
                            }
                            entries.append(
                                .toolResult(
                                    toolUseId:
                                        toolUseId,
                                    content:
                                        resultContent
                                )
                            )
                        }
                    }
                }
            } else if type == "assistant" {
                if let parts = msgContent
                    as? [[String: Any]]
                {
                    for part in parts {
                        let partType = part["type"]
                            as? String ?? ""
                        if partType == "text",
                           let text = part["text"]
                               as? String,
                           !text.isEmpty
                        {
                            entries.append(
                                .assistantText(text)
                            )
                        } else if partType
                            == "tool_use"
                        {
                            let name = part["name"]
                                as? String ?? "unknown"
                            let id = part["id"]
                                as? String ?? ""
                            let input = part["input"]
                                as? [String: Any]
                                ?? [:]
                            let detail =
                                toolUseDetail(
                                    name: name,
                                    input: input
                                )
                            entries.append(
                                .toolUse(
                                    id: id,
                                    name: name,
                                    detail: detail
                                )
                            )
                        }
                    }
                }
            }
        }

        return ParsedTranscript(
            entries: entries,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            agentId: agentId,
            messageCount: messageCount
        )
    }

    /// Extract a human-readable detail string from
    /// a tool_use input.
    static func toolUseDetail(
        name: String,
        input: [String: Any]
    ) -> String {
        switch name {
        case "Read":
            if let path = input["file_path"]
                as? String
            {
                return abbreviatePath(path)
            }
        case "Bash":
            if let cmd = input["command"] as? String {
                return cmd
            }
        case "Glob":
            if let pattern = input["pattern"]
                as? String
            {
                return pattern
            }
        case "Grep":
            if let pattern = input["pattern"]
                as? String
            {
                let path = input["path"]
                    as? String ?? ""
                if path.isEmpty { return pattern }
                return "\(pattern) in "
                    + abbreviatePath(path)
            }
        case "Edit":
            if let path = input["file_path"]
                as? String
            {
                return abbreviatePath(path)
            }
        case "Write":
            if let path = input["file_path"]
                as? String
            {
                return abbreviatePath(path)
            }
        default:
            break
        }

        // Fallback: show first string value
        for (_, value) in input {
            if let str = value as? String,
               !str.isEmpty
            {
                return String(str.prefix(120))
            }
        }
        return ""
    }

    /// Split text into annotatable chunks. First splits
    /// on double-newline boundaries into paragraphs,
    /// then splits paragraphs that contain list items
    /// into individual items. Handles ordered (1. ),
    /// unordered (- , * ), and indented sub-lists.
    static func splitAnnotatableChunks(
        _ text: String
    ) -> [String] {
        let paragraphs = text.components(
            separatedBy: "\n\n"
        )
        .map { $0.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) }
        .filter { !$0.isEmpty }

        var chunks: [String] = []
        for para in paragraphs {
            let lines = para.components(
                separatedBy: "\n"
            )
            // Check if this paragraph contains
            // list items
            let hasListItems = lines.contains {
                isListItem($0)
            }
            if !hasListItems {
                chunks.append(para)
                continue
            }
            // Split into header text + individual
            // list items. Indented continuation lines
            // attach to the preceding item.
            var currentItem: String? = nil
            for line in lines {
                if isListItem(line) {
                    // Flush previous item
                    if let item = currentItem {
                        chunks.append(item)
                    }
                    currentItem = line
                } else if currentItem != nil,
                          line.hasPrefix("  ")
                              || line.hasPrefix("\t")
                {
                    // Indented continuation of
                    // current list item
                    currentItem! += "\n" + line
                } else {
                    // Non-list, non-continuation
                    // line — flush and emit as
                    // its own chunk
                    if let item = currentItem {
                        chunks.append(item)
                        currentItem = nil
                    }
                    let trimmed = line
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    if !trimmed.isEmpty {
                        chunks.append(trimmed)
                    }
                }
            }
            if let item = currentItem {
                chunks.append(item)
            }
        }
        return chunks
    }

    /// Detect if a line is a list item:
    /// ordered (1. ), unordered (- , * ), or
    /// indented variants.
    static func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(
            in: .whitespaces
        )
        if trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
        {
            return true
        }
        // Check for ordered list: digits followed
        // by . and space
        var i = trimmed.startIndex
        while i < trimmed.endIndex,
              trimmed[i].isNumber
        {
            i = trimmed.index(after: i)
        }
        if i > trimmed.startIndex,
           i < trimmed.endIndex,
           trimmed[i] == ".",
           trimmed.index(after: i) < trimmed.endIndex,
           trimmed[trimmed.index(after: i)] == " "
        {
            return true
        }
        return false
    }

    /// Shorten home directory prefix to ~
    static func abbreviatePath(
        _ path: String
    ) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - HTML Generation

    public static func document(
        content: String,
        isDark: Bool
    ) -> String {
        // Shared palette from the engine. The local names stay: the stylesheet
        // below is nearly two hundred lines of interpolation, and renaming
        // through all of it would buy nothing but risk a great deal.
        let theme = ReaderTheme.standard(isDark: isDark)
        let bgColor = theme.background
        let textColor = theme.foreground
        let mutedColor = theme.mutedForeground
        let borderColor = theme.border
        let cardBg = theme.raisedSurface
        let codeBg = theme.sunkenSurface
        let accentColor = theme.accent
        let toolBadgeBg = isDark
            ? "#1f2937" : "#e5e7eb"
        let toolBadgeColor = isDark
            ? "#93c5fd" : "#1e40af"
        let promptBg = isDark ? "#0c2d6b" : "#dbeafe"
        let promptBorder = isDark
            ? "#1d4ed8" : "#93c5fd"
        let summaryBorderColor = isDark
            ? "#16a34a" : "#22c55e"
        let summaryBg = isDark ? "#0c3527" : "#dcfce7"
        let summaryBorder = isDark
            ? "#16a34a" : "#86efac"


        let parsed = parseTranscript(content)
        let entries = parsed.entries

        guard !entries.isEmpty else {
            return """
            <html><body style="background:\(bgColor);\
            color:\(textColor);padding:24px">\
            No transcript data</body></html>
            """
        }

        let toolCallCount = entries.filter {
            if case .toolUse = $0 { return true }
            return false
        }.count

        // Extract initial prompt (first userText)
        // and split into annotatable paragraphs.
        var promptHTML = ""
        var entryStart = 0
        var blockIndex = 1
        if case .userText(let text) = entries.first {
            let paragraphs = splitAnnotatableChunks(text)
            var inner = ""
            for para in paragraphs {
                inner += """
                <div class="transcript-step \
                prompt-para"
                     data-block-index="\(
                         blockIndex
                     )">\(
                    HTMLEscape.text(para)
                )</div>
                """
                blockIndex += 1
            }
            promptHTML = inner
            entryStart = 1
        }

        // Group remaining entries into steps.
        // Each assistant text or tool_use is a step.
        // Tool results attach to their preceding
        // tool_use.
        var stepsHTML = ""
        var pendingToolUse: (
            id: String, name: String, detail: String
        )? = nil

        for i in entryStart..<entries.count {
            let entry = entries[i]

            switch entry {
            case .userText:
                continue

            case .assistantText(let text):
                if let pending = pendingToolUse {
                    stepsHTML += buildToolUseStep(
                        blockIndex: blockIndex,
                        name: pending.name,
                        detail: pending.detail,
                        resultContent: nil,
                        codeBg: codeBg,
                        borderColor: borderColor,
                        mutedColor: mutedColor,
                        toolBadgeBg: toolBadgeBg,
                        toolBadgeColor: toolBadgeColor
                    )
                    blockIndex += 1
                    pendingToolUse = nil
                }

                let isLastAssistant: Bool = {
                    for j in (i + 1)..<entries.count {
                        if case .assistantText =
                            entries[j]
                        {
                            return false
                        }
                    }
                    return true
                }()

                if isLastAssistant && text.count > 500 {
                    let paragraphs =
                        splitAnnotatableChunks(text)
                    stepsHTML += """
                    <div class="summary-container">
                    <div class="step-label">\
                    Summary</div>
                    """
                    for para in paragraphs {
                        stepsHTML += """
                        <div class="transcript-step \
                        summary-para"
                             data-block-index="\(
                                 blockIndex
                             )">\(
                            HTMLEscape.text(para)
                        )</div>
                        """
                        blockIndex += 1
                    }
                    stepsHTML += "</div>"
                } else {
                    stepsHTML += """
                    <div class="transcript-step \
                    thinking-step"
                         data-block-index="\(
                             blockIndex
                         )">
                    <div class="step-label">\
                    Thinking</div>
                    <div class="thinking-content">\(
                        HTMLEscape.text(text)
                    )</div>
                    </div>
                    """
                    blockIndex += 1
                }

            case .toolUse(
                let id, let name, let detail
            ):
                if let pending = pendingToolUse {
                    stepsHTML += buildToolUseStep(
                        blockIndex: blockIndex,
                        name: pending.name,
                        detail: pending.detail,
                        resultContent: nil,
                        codeBg: codeBg,
                        borderColor: borderColor,
                        mutedColor: mutedColor,
                        toolBadgeBg: toolBadgeBg,
                        toolBadgeColor: toolBadgeColor
                    )
                    blockIndex += 1
                }
                pendingToolUse = (id, name, detail)

            case .toolResult(_, let result):
                if let pending = pendingToolUse {
                    stepsHTML += buildToolUseStep(
                        blockIndex: blockIndex,
                        name: pending.name,
                        detail: pending.detail,
                        resultContent: result,
                        codeBg: codeBg,
                        borderColor: borderColor,
                        mutedColor: mutedColor,
                        toolBadgeBg: toolBadgeBg,
                        toolBadgeColor: toolBadgeColor
                    )
                    blockIndex += 1
                    pendingToolUse = nil
                }
            }
        }

        // Flush final pending tool_use
        if let pending = pendingToolUse {
            stepsHTML += buildToolUseStep(
                blockIndex: blockIndex,
                name: pending.name,
                detail: pending.detail,
                resultContent: nil,
                codeBg: codeBg,
                borderColor: borderColor,
                mutedColor: mutedColor,
                toolBadgeBg: toolBadgeBg,
                toolBadgeColor: toolBadgeColor
            )
            blockIndex += 1
        }

        let totalBlocks = blockIndex - 1

        return ReaderDocument.render(
            theme: theme,
            lineHeight: "1.5",
            css: """
            .transcript-container {
                max-width: 900px;
                margin: 0 auto;
                padding: 16px 24px;
            }
            .stats-bar {
                display: flex;
                gap: 16px;
                padding: 8px 12px;
                background: \(cardBg);
                border: 1px solid \(borderColor);
                border-radius: 6px;
                margin-bottom: 16px;
                font-size: 12px;
                color: \(mutedColor);
                font-family: "SF Mono", monospace;
                flex-wrap: wrap;
            }
            .stats-bar .stat-value {
                color: \(textColor);
                font-weight: 600;
            }
            .prompt-block {
                padding: 12px 16px;
                background: \(promptBg);
                border: 1px solid \(promptBorder);
                border-radius: 6px;
                margin-bottom: 16px;
                font-size: 13px;
                line-height: 1.6;
            }
            .prompt-block .prompt-para {
                border: none;
                border-radius: 0;
                padding: 4px 0;
                margin-bottom: 4px;
                white-space: pre-wrap;
                word-wrap: break-word;
            }
            .prompt-block .prompt-para:last-child {
                margin-bottom: 0;
            }
            .prompt-label {
                font-size: 11px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                color: \(accentColor);
                margin-bottom: 6px;
                font-family: "SF Mono", monospace;
            }
            .transcript-step {
                margin-bottom: 8px;
                border: 1px solid \(borderColor);
                border-radius: 6px;
                padding: 8px 12px;
            }
            .step-label {
                font-size: 11px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.05em;
                color: \(mutedColor);
                margin-bottom: 4px;
                font-family: "SF Mono", monospace;
            }
            .thinking-step {
                border-left: 3px solid \(mutedColor);
            }
            .thinking-content {
                white-space: pre-wrap;
                word-wrap: break-word;
                font-size: 13px;
                line-height: 1.5;
            }
            .tool-step {
                border-left: 3px solid \(accentColor);
            }
            .tool-badge {
                display: inline-block;
                padding: 1px 8px;
                border-radius: 4px;
                font-size: 12px;
                font-weight: 600;
                font-family: "SF Mono", monospace;
                background: \(toolBadgeBg);
                color: \(toolBadgeColor);
            }
            .tool-detail {
                margin-top: 4px;
                font-family: "SF Mono", monospace;
                font-size: 12px;
                color: \(textColor);
                white-space: pre-wrap;
                word-wrap: break-word;
            }
            details {
                margin-top: 6px;
            }
            details summary {
                cursor: pointer;
                font-size: 11px;
                color: \(mutedColor);
                font-family: "SF Mono", monospace;
                user-select: none;
            }
            details summary:hover {
                color: \(accentColor);
            }
            details .tool-result-content {
                margin-top: 4px;
                padding: 8px;
                background: \(codeBg);
                border: 1px solid \(borderColor);
                border-radius: 4px;
                font-family: "SF Mono", monospace;
                font-size: 11px;
                line-height: 1.4;
                white-space: pre-wrap;
                word-wrap: break-word;
                max-height: 300px;
                overflow-y: auto;
            }
            .summary-container {
                background: \(summaryBg);
                border: 1px solid \(summaryBorder);
                border-left: 3px solid \(
                    summaryBorderColor
                );
                border-radius: 6px;
                padding: 12px 16px;
                margin-top: 16px;
                margin-bottom: 8px;
            }
            .summary-container .step-label {
                color: \(
                    isDark ? "#4ade80" : "#16a34a"
                );
            }
            .summary-container .summary-para {
                border: none;
                border-radius: 0;
                padding: 4px 0;
                margin-bottom: 4px;
                white-space: pre-wrap;
                word-wrap: break-word;
                font-size: 13px;
                line-height: 1.6;
            }
            .summary-container .summary-para:last-child {
                margin-bottom: 0;
            }
            .transcript-step.annotation-highlight {
                background-color:
                    rgba(88, 166, 255, 0.12);
                border-left-color:
                    rgba(88, 166, 255, 0.6);
            }
            .transcript-step\
            .annotation-expanded-highlight {
                background-color:
                    var(--annotation-active-block-bg);
                border-left-color:
                    var(--annotation-active-block-border);
            }
            """,
            body: """
            <div class="transcript-container">
                <div class="stats-bar">
                    <span><span class="stat-value">\(
                        parsed.messageCount
                    )</span> messages</span>
                    <span><span class="stat-value">\(
                        toolCallCount
                    )</span> tool calls</span>
                    <span><span class="stat-value">\(
                        totalBlocks
                    )</span> steps</span>
                    <span><span class="stat-value">\(
                        formatTokenCount(
                            parsed.totalInputTokens
                        )
                    )</span> input tokens</span>
                    <span><span class="stat-value">\(
                        formatTokenCount(
                            parsed.totalOutputTokens
                        )
                    )</span> output tokens</span>
                </div>\
            \(promptHTML.isEmpty ? "" : """

                <div class="prompt-block">
                    <div class="prompt-label">Prompt</div>
                    \(promptHTML)
                </div>
            """)
                \(stepsHTML)
            </div>
            """
        )
    }

    /// Build HTML for a single tool_use step,
    /// optionally including a collapsible result.
    static func buildToolUseStep(
        blockIndex: Int,
        name: String,
        detail: String,
        resultContent: String?,
        codeBg: String,
        borderColor: String,
        mutedColor: String,
        toolBadgeBg: String,
        toolBadgeColor: String
    ) -> String {
        let escapedDetail =
            HTMLEscape.text(detail)
        let resultHTML: String
        if let result = resultContent,
           !result.isEmpty
        {
            let truncated: String
            let charLimit = 10_000
            if result.count > charLimit {
                truncated = String(
                    result.prefix(charLimit)
                ) + "\n\n… (\(result.count - charLimit)"
                    + " chars truncated)"
            } else {
                truncated = result
            }
            let escaped =
                HTMLEscape.text(truncated)
            resultHTML = """
            <details>
            <summary>Show result (\(
                formatByteCount(result.count)
            ))</summary>
            <div class="tool-result-content">\(
                escaped
            )</div>
            </details>
            """
        } else {
            resultHTML = ""
        }

        return """
        <div class="transcript-step tool-step"
             data-block-index="\(blockIndex)">
        <span class="tool-badge">\(
            HTMLEscape.text(name)
        )</span>
        <div class="tool-detail">\(
            escapedDetail
        )</div>
        \(resultHTML)
        </div>
        """
    }

    /// Format token count with comma separators.
    static func formatTokenCount(
        _ count: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(
            from: NSNumber(value: count)
        ) ?? "\(count)"
    }

    /// Format character count for tool result
    /// summaries.
    static func formatByteCount(
        _ count: Int
    ) -> String {
        if count < 1_000 {
            return "\(count) chars"
        } else if count < 100_000 {
            let k = Double(count) / 1_000.0
            return String(
                format: "%.1fk chars", k
            )
        } else {
            let k = count / 1_000
            return "\(k)k chars"
        }
    }
}
