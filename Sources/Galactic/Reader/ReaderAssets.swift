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
    /// highlight.js, for source and fenced-code rendering.
    public static let highlightJS: String = load("highlight.min", "js")

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
