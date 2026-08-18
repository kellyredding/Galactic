import XCTest

@testable import Galactic

/// What `FileKind` answers today, pinned before it is widened.
///
/// One table decides which reader opens a file, how that reader anchors, what
/// its language is called, and how big is too big. Nothing asserted it until
/// now, and it is about to grow a branch for files that carry no extension.
///
/// The value that must not move is the fallback. An extension this package has
/// no reader for resolves to `.unhandled` carrying that extension, and Galaxy
/// dispatches its diff reader on exactly `.unhandled("gdiff")`. A widening that
/// reached the fallback would render a diff as raw JSON, with the reader, the
/// anchoring and the sessions-panel condition all quietly following it.
final class FileKindTests: XCTestCase {

    // MARK: - The fallback everything else rests on

    /// The one resolution another repository depends on by value.
    func testAnUnknownExtensionComesBackCarryingItself() {
        XCTAssertEqual(
            FileKind.resolve(filename: "changes.gdiff"),
            .unhandled("gdiff"),
            "Galaxy's diff reader dispatches on this exact value"
        )
        XCTAssertEqual(
            FileKind.resolve(filename: "archive.zip"),
            .unhandled("zip")
        )
        XCTAssertEqual(
            FileKind.resolve(filename: "report.pdf"),
            .unhandled("pdf")
        )
    }

    /// A build file carries its meaning in the whole name and a dotfile in
    /// its leading dot, so both are asked as names.
    func testAFileWithNoExtensionIsNamedByItsWholeName() {
        for name in [
            "Makefile", "README", "LICENSE", "Dockerfile", "Gemfile",
            ".gitignore", ".bashrc", ".editorconfig", ".env",
        ] {
            XCTAssertEqual(
                FileKind.resolve(filename: name),
                .source,
                "\(name) is read as source by its name"
            )
        }
    }

    /// A name the set does not know still resolves the old way, so the
    /// fallback is narrowed rather than removed.
    func testAnUnknownExtensionlessNameIsStillUnhandled() {
        XCTAssertEqual(
            FileKind.resolve(filename: "somebinary"),
            .unhandled("")
        )
        XCTAssertEqual(FileKind.resolve(filename: ".DS_Store"), .unhandled(""))
    }

    /// Both spellings now answer. The extension entries were written for the
    /// dotfiles and never reached them; they are kept because a file named
    /// `Node.gitignore` is a real thing.
    func testBothSpellingsOfADotfileReadAsSource() {
        XCTAssertEqual(FileKind.resolve(filename: "Node.gitignore"), .source)
        XCTAssertEqual(FileKind.resolve(filename: ".gitignore"), .source)
    }

    /// The trap in the name set: only a dot-led name with no *further* dot
    /// arrives at the name lookup. Anything carrying its own suffix is
    /// answered by the extension table, so listing it as a name would be dead.
    func testADotLedNameCarryingASuffixResolvesByThatSuffix() {
        XCTAssertEqual(FileKind.resolve(filename: ".mise.toml"), .source)
        XCTAssertEqual(FileKind.resolve(filename: ".eslintrc.json"), .source)
        XCTAssertEqual(
            FileKind.resolve(filename: ".secret.bin"),
            .unhandled("bin"),
            "the suffix decides, and this one has no reader"
        )
    }

    /// Deliberately absent from the source set. Half of these are binary and
    /// share the extension with the XML half, and a host that reads bytes into
    /// a String before asking anything would render those as garbage.
    func testABinaryCapableExtensionIsLeftToTheSystem() {
        XCTAssertEqual(
            FileKind.resolve(filename: "Info.plist"),
            .unhandled("plist")
        )
    }

    // MARK: - The hard-coded branches

    func testMarkdownIsResolvedByExtension() {
        XCTAssertEqual(FileKind.resolve(filename: "notes.md"), .markdown)
        XCTAssertEqual(FileKind.resolve(filename: "notes.markdown"), .markdown)
    }

    func testSeparatedValuesResolveToATable() {
        XCTAssertEqual(FileKind.resolve(filename: "rows.csv"), .table)
        XCTAssertEqual(FileKind.resolve(filename: "rows.tsv"), .table)
    }

    func testDiagramsResolveToMermaid() {
        XCTAssertEqual(FileKind.resolve(filename: "flow.mmd"), .mermaid)
        XCTAssertEqual(FileKind.resolve(filename: "flow.mermaid"), .mermaid)
    }

    func testMarkupResolvesToHTML() {
        XCTAssertEqual(FileKind.resolve(filename: "page.html"), .html)
        XCTAssertEqual(FileKind.resolve(filename: "page.htm"), .html)
    }

    /// Six extensions, and `svg` is among them — it is read as a picture
    /// rather than as the markup it is made of.
    func testTheSixImageExtensions() {
        for ext in ["png", "jpg", "jpeg", "gif", "svg", "webp"] {
            XCTAssertEqual(
                FileKind.resolve(filename: "shot.\(ext)"),
                .image,
                "\(ext) is one of the six"
            )
        }
    }

    func testAKnownSourceExtensionResolvesToSource() {
        for ext in ["rb", "cr", "swift", "py", "ts", "yml", "json", "txt"] {
            XCTAssertEqual(
                FileKind.resolve(filename: "thing.\(ext)"),
                .source,
                "\(ext) is in the source set"
            )
        }
    }

    /// The C family, the shells beyond bash, and the infrastructure and
    /// template formats a file browser meets in the first minute.
    func testTheWidenedSourceExtensions() {
        let widened = [
            "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
            "cs", "vb", "php", "pl", "lua", "r", "scala", "clj",
            "ex", "exs", "elm", "dart", "hs", "ml", "nim", "zig",
            "jl", "sol", "vim", "awk", "coffee",
            "fish", "ps1", "bat",
            "mk", "cmake", "gradle", "groovy", "tf", "hcl", "bzl",
            "xcconfig", "entitlements", "lock", "properties",
            "jsonc", "json5", "ndjson", "graphql", "gql", "wat",
            "rst", "adoc", "tex", "mdx",
            "diff", "patch",
            "erb", "haml", "slim", "liquid", "hbs", "mustache",
            "jinja", "tmpl",
            "sass", "styl", "svelte", "astro",
        ]
        for ext in widened {
            XCTAssertEqual(
                FileKind.resolve(filename: "thing.\(ext)"),
                .source,
                "\(ext) is read as source"
            )
        }
    }

    func testResolutionIgnoresCase() {
        XCTAssertEqual(FileKind.resolve(filename: "README.MD"), .markdown)
        XCTAssertEqual(FileKind.resolve(filename: "SHOT.PNG"), .image)
        XCTAssertEqual(FileKind.resolve(filename: "Main.SWIFT"), .source)
    }

    // MARK: - The one content sniff

    private static let transcriptLine =
        #"{"agentId":"a1b2c3","message":{"role":"assistant"}}"#

    func testAJSONLTranscriptIsRecognisedByShape() {
        XCTAssertEqual(
            FileKind.resolve(
                filename: "agent.jsonl",
                firstLine: Self.transcriptLine
            ),
            .transcript
        )
        XCTAssertTrue(
            FileKind.isAgentTranscript(firstLine: Self.transcriptLine)
        )
    }

    /// Both halves of the shape are required, and a stream of unrelated
    /// records shares the suffix.
    func testJSONLThatIsNotATranscriptFallsBackToSource() {
        let cases = [
            #"{"message":{"role":"assistant"}}"#,      // no agentId
            #"{"agentId":"a1","message":{}}"#,          // no role
            #"{"agentId":"a1"}"#,                       // no message
            #"{"agentId":42,"message":{"role":"x"}}"#,  // agentId not a string
            #"[1,2,3]"#,                                // not an object
            "not json at all",
            "",
        ]
        for line in cases {
            XCTAssertFalse(
                FileKind.isAgentTranscript(firstLine: line),
                "\(line) is not a transcript"
            )
            XCTAssertEqual(
                FileKind.resolve(filename: "data.jsonl", firstLine: line),
                .source
            )
        }
    }

    /// A caller that has not read the file gets the same answer the sniff
    /// itself falls back to.
    func testJSONLWithNoFirstLineIsSource() {
        XCTAssertFalse(FileKind.isAgentTranscript(firstLine: nil))
        XCTAssertEqual(
            FileKind.resolve(filename: "data.jsonl", firstLine: nil),
            .source
        )
        XCTAssertEqual(FileKind.resolve(filename: "data.jsonl"), .source)
    }

    // MARK: - The questions asked before there is any content

    func testIsImageAnswersFromTheNameAlone() {
        XCTAssertTrue(FileKind.isImage("diagram.svg"))
        XCTAssertTrue(FileKind.isImage("shot.png"))
        XCTAssertFalse(FileKind.isImage("notes.md"))
        XCTAssertFalse(FileKind.isImage("Makefile"))
    }

    // MARK: - What each kind hands back

    /// Anchoring is delegated to the renderer that emits the markup, so this
    /// pins the delegation rather than the selectors themselves.
    func testEachKindAnchorsAsItsOwnRendererDoes() {
        let pairs: [(FileKind, ReaderAnchoring)] = [
            (.markdown, MarkdownRenderer.anchoring),
            (.source, SourceRenderer.anchoring),
            (.html, HTMLRenderer.anchoring),
            (.table, TableRenderer.anchoring),
            (.transcript, TranscriptRenderer.anchoring),
            (.image, ImageRenderer.anchoring),
            (.mermaid, MermaidRenderer.anchoring),
        ]
        for (kind, expected) in pairs {
            XCTAssertEqual(kind.anchoring.anchorType, expected.anchorType)
            XCTAssertEqual(
                kind.anchoring.blockSelector,
                expected.blockSelector
            )
            XCTAssertEqual(kind.anchoring.lineAttr, expected.lineAttr)
        }
    }

    /// A kind with no reader still has to say how it would be anchored, and it
    /// borrows the source reader's answer — which is what lets a host render an
    /// unhandled file as source without this table knowing.
    func testAnUnhandledKindAnchorsLikeSource() {
        XCTAssertEqual(
            FileKind.unhandled("gdiff").anchoring.anchorType,
            SourceRenderer.anchoring.anchorType
        )
        XCTAssertEqual(
            FileKind.unhandled("gdiff").anchoring.blockSelector,
            SourceRenderer.anchoring.blockSelector
        )
    }

    func testTheDefaultSizeCaps() {
        XCTAssertEqual(FileKind.markdown.defaultSizeCap, 512_000)
        XCTAssertEqual(FileKind.image.defaultSizeCap, 26_214_400)
        XCTAssertEqual(FileKind.mermaid.defaultSizeCap, 102_400)
        for kind: FileKind in [
            .source, .html, .table, .transcript, .unhandled("gdiff"),
        ] {
            XCTAssertEqual(kind.defaultSizeCap, 2_000_000)
        }
    }

    func testIsUnhandledAnswersForTheOneCase() {
        XCTAssertTrue(FileKind.unhandled("zip").isUnhandled)
        XCTAssertTrue(FileKind.unhandled("").isUnhandled)
        XCTAssertFalse(FileKind.source.isUnhandled)
        XCTAssertFalse(FileKind.image.isUnhandled)
    }

    // MARK: - Highlighting

    func testAKnownExtensionNamesItsLanguage() {
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.rb"), "ruby"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.cr"), "crystal"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.sh"), "bash"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "A.SWIFT"), "swift"
        )
    }

    /// Nine entries are read as source and styled as nothing. The doc on
    /// `sourceExtensions` says everything there "also has, or falls back from,"
    /// a language — this is the falls-back-from half, pinned so the count is
    /// visible when the two sets are widened together.
    func testNineSourceExtensionsHaveNoLanguage() {
        let unstyled = [
            "txt", "log", "conf", "cfg", "ini", "env",
            "gitignore", "dockerignore", "editorconfig",
        ]
        for ext in unstyled {
            XCTAssertNil(
                FileKind.highlightLanguage(forFilename: "a.\(ext)"),
                "\(ext) is read as source and rendered unstyled"
            )
        }
        XCTAssertEqual(unstyled.count, 9)
    }

    /// The other direction: five languages are mapped for extensions that are
    /// not in the source set at all, because their kind has its own renderer.
    func testSomeLanguagesBelongToKindsThatAreNotSource() {
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.jsonl"), "json"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.html"), "xml"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.htm"), "xml"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.csv"), "plaintext"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "a.mmd"), "plaintext"
        )
    }

    /// The extension is asked first, the whole name second — so a file with no
    /// extension still has a language.
    func testAFileWithNoExtensionCanStillNameItsLanguage() {
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "Makefile"), "makefile"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "Gemfile"), "ruby"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: ".bashrc"), "bash"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: ".editorconfig"), "ini"
        )
    }

    /// A path, not just a bare name — the name lookup takes the last
    /// component, the way the extension lookup does.
    func testTheNameLookupTakesTheLastPathComponent() {
        XCTAssertEqual(
            FileKind.resolve(filename: "/a/b/Makefile"), .source
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "/a/b/Makefile"),
            "makefile"
        )
    }

    /// Only what the vendored bundle registers gets a name. It ships the
    /// common subset, so plenty of the widened extensions render unstyled —
    /// which beats naming a language the page cannot load and letting
    /// auto-detection guess.
    func testAnExtensionTheBundleCannotStyleHasNoLanguage() {
        for ext in ["zig", "elm", "nim", "hcl", "tf", "svelte", "adoc"] {
            XCTAssertNil(
                FileKind.highlightLanguage(forFilename: "a.\(ext)"),
                "\(ext) is read as source and rendered unstyled"
            )
        }
        XCTAssertNil(FileKind.highlightLanguage(forFilename: "README"))
    }

    func testTheWidenedLanguageMappings() {
        let expected = [
            "a.c": "c", "a.h": "c", "a.cpp": "cpp", "a.hpp": "cpp",
            "a.m": "objectivec", "a.mm": "objectivec",
            "a.cs": "csharp", "a.vb": "vbnet",
            "a.php": "php", "a.pl": "perl", "a.lua": "lua", "a.r": "r",
            "a.fish": "bash", "a.mk": "makefile",
            "a.jsonc": "json", "a.ndjson": "json",
            "a.erb": "xml", "a.entitlements": "xml", "a.sass": "scss",
            "a.diff": "diff", "a.patch": "diff",
            "a.graphql": "graphql", "a.wat": "wasm",
        ]
        for (filename, language) in expected {
            XCTAssertEqual(
                FileKind.highlightLanguage(forFilename: filename),
                language,
                "\(filename) is styled as \(language)"
            )
        }
    }

    /// Markdown is the most-read extension in either app and had no highlight
    /// language, which used to mean "auto-detect" and now means "leave alone" —
    /// so its absence went from invisible to visible.
    func testMarkdownNamesAHighlightLanguage() {
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "README.md"), "markdown"
        )
        XCTAssertEqual(
            FileKind.highlightLanguage(forFilename: "notes.markdown"),
            "markdown"
        )
    }

    /// Plain text names none, and that is the answer rather than a gap: the
    /// renderer leaves an unnamed language alone instead of guessing at one.
    func testPlainTextNamesNoLanguage() {
        XCTAssertNil(FileKind.highlightLanguage(forFilename: "prompts.txt"))
    }
}
