import Foundation

// MARK: - Extended AnnotationMessage

/// Extended AnnotationMessage enum that supports all
/// anchor types.
public enum AnnotationMessage {
    case create(
        startLine: Int32,
        endLine: Int32,
        content: String
    )
    /// Like `.create`, but with a per-row payload
    /// captured from a diff view's rendered DOM. Each
    /// row carries `file_path`, `file_status`, `kind`
    /// (`add`/`delete`/`context`/`file-header`/
    /// `hunk-sep`/`binary`), optional `old_line` /
    /// `new_line`, and the row's code content. Used
    /// to build a structured `diff_range` anchor_data
    /// so reviewing agents can make sense of the
    /// selection without re-parsing the .gdiff.
    ///
    /// `filePath` / `fileStartLine` / `fileEndLine` /
    /// `fileLineSide` lift the per-file reference out
    /// of `rows[]` so the display label and collapse
    /// logic can read them at the top level without
    /// re-scanning per-row entries. Optional — a
    /// header-only selection leaves the line numbers
    /// nil, and pre-change annotations lack them
    /// entirely.
    case createDiffRange(
        startLine: Int32,
        endLine: Int32,
        rows: [[String: Any]],
        filePath: String?,
        fileStartLine: Int32?,
        fileEndLine: Int32?,
        fileLineSide: String?,
        content: String
    )
    case createRowRange(
        startRow: Int32,
        endRow: Int32,
        content: String
    )
    case createBlockRange(
        startBlock: Int32,
        endBlock: Int32,
        blockContent: String?,
        content: String
    )
    case createWhole(content: String)
    case update(number: Int32, content: String)
    case delete(number: Int32)
    case confirmDragReplace(startIdx: Int, endIdx: Int)
    /// Diff reader's Viewed checkbox was toggled for a
    /// file. Emitted alongside annotation messages on
    /// the same `annotation` message channel to avoid
    /// wiring a second WebKit handler for a single
    /// boolean. Not an annotation; the enum just
    /// carries it because this is the channel that
    /// already exists between the reader DOM and the
    /// app.
    case setViewed(filePath: String, isViewed: Bool)
    /// The send bar was pressed, by click or by chord.
    ///
    /// Carries nothing. The app already holds the
    /// annotations and composes its own message — a
    /// scrollback note ships inline, a persisted
    /// annotation hands off to a review workflow — so
    /// what crosses here is the gesture and not the
    /// payload.
    case reviewWithClaude
}

extension AnnotationMessage {

    /// Parse one message body from the `annotation` channel.
    ///
    /// Extracted so every host shares one dispatch instead of each writing the
    /// subset it currently needs. One reader used to reimplement four of these
    /// nine and fall through on the rest — unreachable while its DOM could
    /// only produce those four, and silent the moment that stopped being true,
    /// because an unmatched action does nothing and says nothing.
    ///
    /// Returns nil for an unrecognised action or a body missing a field the
    /// case requires. A caller that gets nil should do nothing: the page has
    /// already acted locally, and this is the notification, not the command.
    public static func from(_ body: [String: Any]) -> AnnotationMessage? {
        guard let action = body["action"] as? String else { return nil }

        switch action {
        case "create":
            return createMessage(from: body)
        case "update":
            guard let number = body["number"] as? Int,
                  let content = body["content"] as? String
            else { return nil }
            return .update(number: Int32(number), content: content)
        case "delete":
            guard let number = body["number"] as? Int else { return nil }
            return .delete(number: Int32(number))
        case "confirmDragReplace":
            guard let startIdx = body["startIdx"] as? Int,
                  let endIdx = body["endIdx"] as? Int
            else { return nil }
            return .confirmDragReplace(startIdx: startIdx, endIdx: endIdx)
        case "setViewed":
            guard let filePath = body["filePath"] as? String,
                  let isViewed = body["isViewed"] as? Bool
            else { return nil }
            return .setViewed(filePath: filePath, isViewed: isViewed)
        case "reviewWithClaude":
            return .reviewWithClaude
        default:
            return nil
        }
    }

    /// The create family, split out because the anchor type selects between
    /// five payload shapes and nesting that switch made the parent unreadable.
    private static func createMessage(
        from body: [String: Any]
    ) -> AnnotationMessage? {
        let anchorType = body["anchorType"] as? String ?? "line_range"
        let content = body["content"] as? String ?? ""

        switch anchorType {
        case "row_range":
            guard let startRow = body["startRow"] as? Int,
                  let endRow = body["endRow"] as? Int
            else { return nil }
            return .createRowRange(
                startRow: Int32(startRow),
                endRow: Int32(endRow),
                content: content
            )
        case "block_range":
            guard let startBlock = body["startBlock"] as? Int,
                  let endBlock = body["endBlock"] as? Int
            else { return nil }
            return .createBlockRange(
                startBlock: Int32(startBlock),
                endBlock: Int32(endBlock),
                blockContent: body["blockContent"] as? String,
                content: content
            )
        case "whole":
            return .createWhole(content: content)
        default:
            guard let startLine = body["startLine"] as? Int,
                  let endLine = body["endLine"] as? Int
            else { return nil }
            // Per-row anchor data is collected only where the DOM carries it,
            // which today means the diff readers. Its presence is what selects
            // the richer case, rather than the caller declaring a mode.
            guard let rows = body["rows"] as? [[String: Any]], !rows.isEmpty
            else {
                return .create(
                    startLine: Int32(startLine),
                    endLine: Int32(endLine),
                    content: content
                )
            }
            return .createDiffRange(
                startLine: Int32(startLine),
                endLine: Int32(endLine),
                rows: rows,
                filePath: body["filePath"] as? String,
                fileStartLine: (body["fileStartLine"] as? Int).map { Int32($0) },
                fileEndLine: (body["fileEndLine"] as? Int).map { Int32($0) },
                fileLineSide: body["fileLineSide"] as? String,
                content: content
            )
        }
    }
}
