import Foundation

/// What a file is, for the purpose of reading it.
///
/// One table, answering every question a host asks about an extension: which
/// reader opens it, how that reader anchors annotations, what to call its
/// language for highlighting, and how big is too big.
///
/// Galaxy asked those separately, from four tables that had to agree — the
/// reader dispatch, the annotation scope beside it, the language map, and the
/// renderability allowlist with its size caps. Two of them carried comments
/// saying so. They disagreed anyway: a refresh once inverted a diagram's cards
/// because the scope table had a rule the dispatch did not. A fifth copy lives
/// in another language, in the CLI that labels an artifact's type, and it
/// still has to be kept in step by hand — but there is now one Swift answer
/// for it to mirror rather than four.
///
/// ### Extending it
///
/// A kind the engine does not render resolves to `.unhandled`, carrying the
/// extension so a host can dispatch on it. That is the seam for a reader an
/// app keeps to itself: Galaxy maps `.unhandled("gdiff")` to its own diff
/// view, and nothing in here has to know diffs exist.
public enum FileKind: Equatable, Sendable {
    case markdown
    case source
    case html
    case table
    case mermaid
    case image
    case transcript
    /// An extension this package has no reader for, for the host to place.
    case unhandled(String)

    /// Resolve a filename to a kind.
    ///
    /// `firstLine` is consulted only for `.jsonl`, which is the one extension
    /// whose reader depends on what is inside it rather than what it is
    /// called: an agent transcript and a stream of unrelated records share a
    /// suffix. A caller that has not read the file passes nil and gets
    /// `.source`, which is the same fallback the sniff itself falls back to.
    public static func resolve(
        filename: String,
        firstLine: String? = nil
    ) -> FileKind {
        switch (filename as NSString).pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "csv", "tsv":
            return .table
        case "mmd", "mermaid":
            return .mermaid
        case "html", "htm":
            return .html
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return .image
        case "jsonl":
            return isAgentTranscript(firstLine: firstLine)
                ? .transcript : .source
        case let ext where sourceExtensions.contains(ext):
            return .source
        case let ext:
            return .unhandled(ext)
        }
    }

    /// Whether a JSONL first line looks like an agent transcript.
    ///
    /// Structural rather than a marker: an object carrying a string `agentId`
    /// and a nested `message` with a string `role`. Nothing writes a version
    /// field, so the shape is the only signal available.
    public static func isAgentTranscript(firstLine: String?) -> Bool {
        guard
            let firstLine,
            let data = firstLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any],
            dict["agentId"] is String,
            let message = dict["message"] as? [String: Any],
            message["role"] is String
        else { return false }
        return true
    }

    /// Whether this package ships no reader for the kind.
    ///
    /// Not the same question as "can it be shown" — a host that adds a reader
    /// of its own answers that differently, which is what `.unhandled`
    /// carrying its extension is for.
    public var isUnhandled: Bool {
        if case .unhandled = self { return true }
        return false
    }

    /// Whether a filename reads as an image.
    ///
    /// Images are the one kind a host commonly has to answer for before it has
    /// any content to resolve against — they are shown from a path rather than
    /// from text, so the question comes up earlier than the rest of the table.
    public static func isImage(_ filename: String) -> Bool {
        resolve(filename: filename) == .image
    }

    /// How a reader of this kind anchors annotations into its markup.
    public var anchoring: ReaderAnchoring {
        switch self {
        case .markdown:
            return .lines(
                selector: ".md-block",
                lineAttr: "data-line-start",
                endLineAttr: "data-line-end"
            )
        case .source, .unhandled:
            return .lines(selector: ".code-line")
        case .table:
            return .rows()
        case .html:
            return .blocks(selector: ".annotatable-block")
        case .transcript:
            return .blocks(selector: ".transcript-step")
        case .image, .mermaid:
            return .whole
        }
    }

    /// The largest file of this kind worth rendering inline, in bytes.
    ///
    /// A default rather than a rule. A cap is a policy value — it trades a
    /// host's tolerance for a slow open against how often it sends a reader to
    /// the OS instead — so a host is expected to disagree, and these are the
    /// numbers Galaxy arrived at rather than anything derived.
    ///
    /// Images are generous because decoding one is fast and a photo is
    /// routinely large; mermaid is tight because layout cost climbs with the
    /// number of nodes, not the byte count, and a big diagram hangs the page.
    public var defaultSizeCap: Int64 {
        switch self {
        case .markdown: return 512_000
        case .image: return 26_214_400
        case .mermaid: return 102_400
        case .source, .html, .table, .transcript, .unhandled:
            return 2_000_000
        }
    }

    /// The highlight.js language for a filename, or nil to leave it unstyled.
    public static func highlightLanguage(
        forFilename filename: String
    ) -> String? {
        highlightLanguages[
            (filename as NSString).pathExtension.lowercased()
        ]
    }

    /// Extensions read as source. Everything here also has, or falls back
    /// from, an entry in `highlightLanguages`.
    private static let sourceExtensions: Set<String> = [
        "rb", "cr", "py", "js", "ts", "jsx", "tsx", "swift", "go", "rs",
        "java", "kt", "sql", "sh", "bash", "zsh", "yml", "yaml", "json",
        "toml", "xml", "css", "scss", "less", "vue", "txt", "log", "conf",
        "cfg", "ini", "env", "gitignore", "dockerignore", "editorconfig",
    ]

    private static let highlightLanguages: [String: String] = [
        "rb": "ruby", "cr": "crystal",
        "py": "python", "js": "javascript",
        "ts": "typescript", "jsx": "javascript",
        "tsx": "typescript", "swift": "swift",
        "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin",
        "sql": "sql", "sh": "bash",
        "bash": "bash", "zsh": "bash",
        "yml": "yaml", "yaml": "yaml",
        "json": "json", "jsonl": "json",
        "toml": "ini",
        "xml": "xml", "html": "xml",
        "htm": "xml", "css": "css",
        "scss": "scss", "less": "less",
        "vue": "xml", "csv": "plaintext",
        "tsv": "plaintext",
        "mmd": "plaintext",
        "mermaid": "plaintext",
    ]
}
