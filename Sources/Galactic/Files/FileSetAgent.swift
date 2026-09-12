import Foundation

/// A request from an agent about one owner's file sets, as it arrives off a
/// host's socket. Parsed here, not per application, so two hosts cannot read one
/// request two ways.
public enum FileSetAgentRequest: Equatable, Sendable {
    case list
    case view(name: String)
    case open(name: String, paths: [String])
    case show(name: String)
    case rename(name: String, to: String)
    case remove(name: String)

    public static let eventPrefix = "file_set."

    /// Nil for any other event, so a host can offer every request it receives.
    /// A malformed one is a failure rather than nil, so the agent is answered
    /// instead of waiting out its timeout.
    public static func parse(
        event: String, detail: [String: Any]?
    ) -> Result<FileSetAgentRequest, FileSetAgentFailure>? {
        guard event.hasPrefix(eventPrefix) else { return nil }
        let detail = detail ?? [:]

        func text(_ key: String, _ what: String)
            -> Result<String, FileSetAgentFailure>
        {
            guard let value = detail[key] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .failure(.missing(what)) }
            return .success(value)
        }

        let operation = String(event.dropFirst(eventPrefix.count))
        switch operation {
        case "list":
            return .success(.list)
        case "view":
            return text("name", "set name").map {
                FileSetAgentRequest.view(name: $0)
            }
        case "show":
            return text("name", "set name").map {
                FileSetAgentRequest.show(name: $0)
            }
        case "remove":
            return text("name", "set name").map {
                FileSetAgentRequest.remove(name: $0)
            }
        case "rename":
            return text("name", "set name").flatMap { name in
                text("new_name", "new name").map {
                    FileSetAgentRequest.rename(name: name, to: $0)
                }
            }
        case "open":
            return text("name", "set name").flatMap { name in
                guard let raw = detail["paths"] as? [Any], !raw.isEmpty else {
                    return .failure(.missing("files to open"))
                }
                let paths = raw.compactMap { $0 as? String }
                guard paths.count == raw.count else {
                    return .failure(.malformedPaths)
                }
                return .success(.open(name: name, paths: paths))
            }
        default:
            return .failure(.unknownRequest(operation))
        }
    }
}

/// Why an agent's request was refused, in a sentence written to be relayed:
/// "you" is the agent and "the user" the person at the Files tab.
public struct FileSetAgentFailure: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    static func missing(_ what: String) -> FileSetAgentFailure {
        FileSetAgentFailure("The request is missing its \(what).")
    }

    static let malformedPaths = FileSetAgentFailure(
        "The request's files to open are not all paths."
    )

    static func unknownRequest(_ operation: String) -> FileSetAgentFailure {
        FileSetAgentFailure(
            "There is no file-set request called “\(operation)”."
        )
    }

    static func noSuchSet(_ name: String) -> FileSetAgentFailure {
        FileSetAgentFailure("There is no set named “\(name)”.")
    }

    static let defaultIsUsers = FileSetAgentFailure(
        "The default set is the user's own: you can view it and show it, but "
            + "not open files into it, rename it or remove it."
    )

    static func madeByUser(_ name: String) -> FileSetAgentFailure {
        FileSetAgentFailure(
            "“\(name)” was made by the user, and you can only remove sets you "
                + "made."
        )
    }

    static func holdsNotes(_ name: String, count: Int) -> FileSetAgentFailure {
        let one = count == 1
        return FileSetAgentFailure(
            "“\(name)” holds \(count) unsent note\(one ? "" : "s"), so it stays "
                + "until the user sends or discards \(one ? "it" : "them")."
        )
    }

    static func nothingOpened(_ refusals: [FileSetAgentRefusal])
        -> FileSetAgentFailure
    {
        FileSetAgentFailure(
            (["Nothing was opened."] + refusals.map(\.line))
                .joined(separator: "\n")
        )
    }
}

/// A path an open could not use, and why.
struct FileSetAgentRefusal: Equatable {
    let path: String
    let reason: String

    var line: String { "Not opened: \(path) — \(reason)." }
}

/// What an agent is told: one JSON object. A CLI prints a read's object whole,
/// and a change's `message`.
public struct FileSetAgentReply {
    public let isSuccess: Bool

    /// The sentence for a change, or the reason for a refusal. A read has none:
    /// its JSON is the answer.
    public let message: String?

    let fields: [String: Any]

    public static func failure(_ failure: FileSetAgentFailure)
        -> FileSetAgentReply
    {
        FileSetAgentReply(isSuccess: false, message: failure.message, fields: [:])
    }

    static func read(_ fields: [String: Any]) -> FileSetAgentReply {
        FileSetAgentReply(isSuccess: true, message: nil, fields: fields)
    }

    static func changed(_ message: String, _ fields: [String: Any])
        -> FileSetAgentReply
    {
        FileSetAgentReply(isSuccess: true, message: message, fields: fields)
    }

    /// `ok`, plus `error` on a refusal or `message` on a change.
    public var jsonObject: [String: Any] {
        var object = fields
        object["ok"] = isSuccess
        if let message { object[isSuccess ? "message" : "error"] = message }
        return object
    }

    /// Sorted keys, so two hosts write the same bytes for one answer; slashes
    /// unescaped, since nearly every value is a path an agent reads.
    public func jsonData() -> Data {
        (try? JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ))
            ?? Data(#"{"error":"The reply could not be written.","ok":false}"#.utf8)
    }
}
