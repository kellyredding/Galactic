import Foundation

/// The vendored web assets a reader document splices into its page.
///
/// Syntax highlighting and diagram rendering are third-party libraries shipped
/// as bytes. They lived in the app bundle when only one app had readers; they
/// live here now for the same reason the emoji data does — a consumer cannot
/// end up with the code that injects them and not the files themselves.
///
/// Every one of these is **inlined into the document**, not referenced by
/// `<script src>`. A page loaded with `loadHTMLString` has no origin that can
/// resolve a package-bundle URL, so the bytes travel in the HTML. That is also
/// why `mermaid` is worth thinking about before including: it is 3.1 MB, more
/// than twenty times the rest combined, and a document that includes it pays
/// that on every render. Ask a `FileKind` whether the page needs it rather
/// than adding it by default.
///
/// Loaded once and held. A theme change rebuilds the whole document, and
/// re-reading three megabytes from disk on every toggle is a visible pause.
public enum ReaderAssets {
    /// highlight.js, for source and fenced-code rendering, with the grammars
    /// that ship beside it rather than inside it.
    ///
    /// Composed here rather than at the call sites because this property is
    /// the only thing any of them read — the file reader, fenced code, and
    /// Galaxy's diff reader in another package. A grammar injected anywhere
    /// else would reach some of those and silently miss the rest.
    ///
    /// Order is load-bearing. The corrections wrap the registration function,
    /// so they have to be in place before the grammars that arrive through it;
    /// each grammar names itself against the global the library defines, so
    /// the library has to precede both. Ruby is re-registered rather than
    /// merely patched, because the library already registered its own copy
    /// during evaluation, before anything here could intercept it.
    public static let highlightJS: String =
        [highlightLibraryJS, grammarFixesJS, rubyJS, crystalJS]
        .joined(separator: "\n")

    /// The stock upstream bundle, registering its common subset of languages.
    ///
    /// Held apart from the composed `highlightJS` so `ReaderAssetsTests` can
    /// see each file's presence on its own. Concatenated, one of them going
    /// missing still leaves a non-empty string.
    static let highlightLibraryJS: String = load("highlight.min", "js")

    /// The Crystal grammar, which the bundle does not carry.
    ///
    /// Upstream ships it as a standalone file that registers itself against
    /// the global the library defines, so it has to follow the library.
    static let crystalJS: String = load("crystal.min", "js")

    /// The stock Ruby grammar, shipped so it can be registered a second time
    /// with the corrections below applied. Byte-identical to upstream's.
    static let rubyJS: String = load("ruby.min", "js")

    /// Corrections to two upstream grammar defects, applied as each grammar
    /// registers itself.
    ///
    /// The only file here this package wrote. It exists so the two grammar
    /// files beside it can stay byte-identical to upstream and be checked
    /// against a published checksum — the property that let this bundle's
    /// provenance be recovered when nothing in the repository recorded it.
    static let grammarFixesJS: String = load("grammar-fixes", "js")

    /// mermaid.js, for diagram rendering. Large — see the note above.
    public static let mermaidJS: String = load("mermaid.min", "js")

    /// The highlight.js theme matching the reader's appearance.
    ///
    /// Taken as a parameter rather than read from a global appearance, because
    /// a reader's light or dark rendering is a property of the document being
    /// built, not of the process building it — a host can legitimately render
    /// one of each at the same time.
    public static func highlightThemeCSS(isDark: Bool) -> String {
        isDark ? githubDarkCSS : githubLightCSS
    }

    static let githubLightCSS: String = load("github.min", "css")
    static let githubDarkCSS: String = load("github-dark.min", "css")

    /// Missing or unreadable resolves to empty rather than trapping.
    ///
    /// Highlighting and diagrams are layered onto a document that is legible
    /// without them: unhighlighted source is still source, and an unrendered
    /// mermaid block still shows its own definition. Losing an asset should
    /// degrade the page, not stop it rendering. An empty string injects a
    /// harmless empty `<script>` or `<style>`.
    ///
    /// Because that degradation is silent, `ReaderAssetsTests` asserts each
    /// one is non-empty — the failure this guards against is a resource that
    /// stopped being copied into the bundle, which otherwise shows up as
    /// source that quietly renders without colour.
    private static func load(
        _ name: String,
        _ ext: String
    ) -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: ext
            ),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return content
    }
}
