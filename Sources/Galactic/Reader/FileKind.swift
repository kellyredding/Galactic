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
    ///
    /// This answers about a *name*, never about what is on disk. A directory
    /// called `readme` resolves the same way a file called `readme` does, and
    /// telling the two apart is the caller's job — nothing here stats anything.
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
        case "":
            // No extension at all. A build file carries its meaning in the
            // whole name and a dotfile in its leading dot, so both are asked
            // as names rather than as extensions. Only names with no *other*
            // dot arrive here — `.mise.toml` has extension `toml` and was
            // answered above, which is why listing it below would be dead.
            let name = ((filename as NSString).lastPathComponent).lowercased()
            return extensionlessSourceNames.contains(name)
                ? .source : .unhandled("")
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
    ///
    /// Asked of the renderer rather than answered here. A renderer knows the
    /// markup it emits, and stating it twice is how the anchoring and the
    /// document it describes come apart — which is the drift this table was
    /// written to end, arrived at from the other direction.
    public var anchoring: ReaderAnchoring {
        switch self {
        case .markdown: return MarkdownRenderer.anchoring
        case .source, .unhandled: return SourceRenderer.anchoring
        case .table: return TableRenderer.anchoring
        case .html: return HTMLRenderer.anchoring
        case .transcript: return TranscriptRenderer.anchoring
        case .image: return ImageRenderer.anchoring
        case .mermaid: return MermaidRenderer.anchoring
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
    ///
    /// Asked of the extension first and of the whole name second, because a
    /// file with no extension still has a language: `Makefile` and `.bashrc`
    /// are answered by `filenameLanguages`.
    ///
    /// A nil is not a failure. `SourceRenderer` renders an unstyled document
    /// perfectly well, and naming a language this package does not ship is
    /// worse than naming none — `hljs.highlightElement` falls back to
    /// auto-detection, which guesses.
    public static func highlightLanguage(
        forFilename filename: String
    ) -> String? {
        let name = filename as NSString
        if let byExtension = highlightLanguages[
            name.pathExtension.lowercased()
        ] {
            return byExtension
        }
        return filenameLanguages[name.lastPathComponent.lowercased()]
    }

    /// The language, asking the file's first line when its name does not say.
    ///
    /// A shebang is the only other place a file declares what it is, and the
    /// files that carry one are exactly the files with nothing else to go on:
    /// a shim, a hook, a script on a path. `.rb/shims/ri` is a bash script whose
    /// name says `ri`.
    ///
    /// Name first, but only when the name says something. An extension that names
    /// a language is the stronger claim — a `.rb` file launched through bash is
    /// still Ruby — while an extension that names nothing has not disagreed with
    /// anything, so the shebang is taken. A `.txt` whose first line is
    /// `#!/usr/bin/env bash` is a script saved under the wrong name.
    public static func highlightLanguage(
        forFilename filename: String,
        firstLine: String?
    ) -> String? {
        if let byName = highlightLanguage(forFilename: filename) {
            return byName
        }
        guard let firstLine else { return nil }
        return shebangLanguage(firstLine)
    }

    /// The language a `#!` line declares, or nil.
    ///
    /// Reads the interpreter rather than the path: `/bin/bash`, `/usr/bin/env
    /// bash` and `/usr/bin/env -S bash -e` all name bash. A version suffix is
    /// dropped, because `python3` and `python3.12` are the same grammar.
    static func shebangLanguage(_ firstLine: String) -> String? {
        guard firstLine.hasPrefix("#!") else { return nil }

        var tokens = firstLine.dropFirst(2)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let interpreter = tokens.first else { return nil }

        var name = (interpreter as NSString).lastPathComponent
        if name == "env" {
            tokens.removeFirst()
            // `env` takes flags of its own — `-S` splits a string, `-i` clears
            // the environment — and the interpreter is whatever follows them.
            while let next = tokens.first, next.hasPrefix("-") {
                tokens.removeFirst()
            }
            guard let actual = tokens.first else { return nil }
            name = (actual as NSString).lastPathComponent
        }

        return shebangLanguages[versionless(name).lowercased()]
    }

    /// `python3.12` → `python`. Trailing digits and dots only, so a name that
    /// ends in a numeral for another reason is left alone by having no entry.
    private static func versionless(_ name: String) -> String {
        var trimmed = name
        while let last = trimmed.last, last.isNumber || last == "." {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? name : trimmed
    }

    /// Interpreter name → highlighter language.
    ///
    /// Separate from the extension table because the keys are a different
    /// vocabulary: `sh` is an extension *and* an interpreter, but `node` and
    /// `Rscript` are only ever interpreters. Naming one the bundle does not
    /// register is safe — the renderer checks before it highlights and leaves the
    /// source alone otherwise.
    static let shebangLanguages: [String: String] = [
        // Shells, all read as bash
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "dash": "bash", "ksh": "bash", "fish": "bash",
        "python": "python", "ruby": "ruby",
        "node": "javascript", "deno": "javascript", "bun": "javascript",
        "perl": "perl", "php": "php", "lua": "lua",
        "crystal": "crystal", "swift": "swift",
        "rscript": "r", "r": "r",
        "awk": "awk", "gawk": "awk",
        "tclsh": "tcl", "groovy": "groovy",
    ]

    /// Extensions read as source.
    ///
    /// **Never add `gdiff`.** Galaxy dispatches its diff reader on
    /// `.unhandled("gdiff")`, so adding it here would render a diff as raw
    /// JSON with nothing failing. `diff` and `patch` are different strings and
    /// are safe.
    ///
    /// Nor anything routinely binary under a text-looking extension. `plist`
    /// is the one that keeps being suggested and is deliberately absent: half
    /// of them are binary, and a host that reads bytes into a `String` before
    /// asking anything — which is what the artifact reader does — would render
    /// those as garbage rather than hand them to the system.
    ///
    /// `gitignore`, `dockerignore` and `editorconfig` are matched here **and**
    /// as whole names in `extensionlessSourceNames`, deliberately. They were
    /// written for the dotfiles and never reached them, because a leading dot
    /// is not an extension separator — the name set is what answers for
    /// `.gitignore`. These stay because `Node.gitignore` should still read as
    /// source.
    private static let sourceExtensions: Set<String> = [
        // Original set
        "rb", "cr", "py", "js", "ts", "jsx", "tsx", "swift", "go", "rs",
        "java", "kt", "sql", "sh", "bash", "zsh", "yml", "yaml", "json",
        "toml", "xml", "css", "scss", "less", "vue", "txt", "log", "conf",
        "cfg", "ini", "env", "gitignore", "dockerignore", "editorconfig",
        // C family
        "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
        // Other languages
        "cs", "vb", "php", "pl", "lua", "r", "scala", "clj", "ex", "exs",
        "elm", "dart", "hs", "ml", "nim", "zig", "jl", "sol", "vim", "awk",
        "coffee",
        // Shells and scripts
        "fish", "ps1", "bat",
        // Build and infrastructure
        "mk", "cmake", "gradle", "groovy", "tf", "hcl", "bzl",
        "xcconfig", "entitlements", "lock", "properties",
        // Data and config
        "jsonc", "json5", "ndjson", "graphql", "gql", "wat",
        // Prose and markup
        "rst", "adoc", "tex", "mdx",
        // Diffs — distinct from `gdiff`, see above
        "diff", "patch",
        // Templates
        "erb", "haml", "slim", "liquid", "hbs", "mustache", "jinja", "tmpl",
        // Styles and web
        "sass", "styl", "svelte", "astro",
    ]

    /// Whole filenames read as source, for files carrying no extension.
    ///
    /// Dotfiles are listed with their leading dot because that is what
    /// `lastPathComponent` returns. Only dot-led names with no *further* dot
    /// reach this set — `.mise.toml` resolves by its `toml` extension — so
    /// listing a name that carries its own suffix would be dead code.
    private static let extensionlessSourceNames: Set<String> = [
        "makefile", "rakefile", "gemfile", "podfile", "procfile",
        "dockerfile", "vagrantfile", "brewfile", "justfile",
        "readme", "license", "licence", "changelog", "authors",
        "notice", "copying", "codeowners",
        ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig",
        ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile",
        ".env", ".npmrc", ".rspec", ".tool-versions",
        ".ruby-version", ".node-version",
    ]

    /// Extension to highlight.js language.
    ///
    /// Only languages the vendored bundle actually registers appear here. It
    /// ships the common subset — thirty-five languages — so most of what a
    /// repository contains has no entry and renders unstyled, which is the
    /// intended outcome rather than a gap to fill.
    ///
    /// Approximations are used where a family is close enough and there is
    /// precedent: `zsh` and `fish` answer as bash, `vue` and `erb` as xml,
    /// `toml` as ini. `cr` answers as crystal, which the bundle does *not*
    /// register — it predates this note and degrades to auto-detection rather
    /// than failing, so it is left alone.
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
        // Added once the renderer stopped auto-detecting: markdown is the most
        // read extension in either app and was falling through to nil, which
        // used to mean "guess" and now means "leave alone" — so naming it is the
        // difference between headings and links being marked up and a document
        // rendering flat.
        "md": "markdown", "markdown": "markdown",
        "xml": "xml", "html": "xml",
        "htm": "xml", "css": "css",
        "scss": "scss", "less": "less",
        "vue": "xml", "csv": "plaintext",
        "tsv": "plaintext",
        "mmd": "plaintext",
        "mermaid": "plaintext",
        // C family
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
        "hpp": "cpp", "hh": "cpp",
        "m": "objectivec", "mm": "objectivec",
        // Other languages the bundle registers
        "cs": "csharp", "vb": "vbnet",
        "php": "php", "pl": "perl",
        "lua": "lua", "r": "r",
        "wat": "wasm",
        "graphql": "graphql", "gql": "graphql",
        // Shells, by family
        "fish": "bash",
        // Build files
        "mk": "makefile",
        // Data, by family
        "jsonc": "json", "json5": "json", "ndjson": "json",
        // Markup, by family
        "erb": "xml", "entitlements": "xml",
        "sass": "scss",
        // Diffs
        "diff": "diff", "patch": "diff",
    ]

    /// Whole filename to highlight.js language, for files with no extension.
    ///
    /// Consulted only after `highlightLanguages` misses, so a name that
    /// carries a suffix never reaches this table.
    private static let filenameLanguages: [String: String] = [
        "makefile": "makefile",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby",
        "vagrantfile": "ruby", "brewfile": "ruby",
        ".bashrc": "bash", ".bash_profile": "bash",
        ".zshrc": "bash", ".zprofile": "bash",
        ".profile": "bash", ".env": "bash",
        ".editorconfig": "ini", ".npmrc": "ini",
    ]
}
