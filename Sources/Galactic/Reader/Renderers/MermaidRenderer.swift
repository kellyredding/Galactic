import Foundation

/// Renders a Mermaid source file as a rendered diagram.
///
/// The diagram is the whole document, so an annotation on one is about all
/// of it — there are no rows or blocks to point at.
public enum MermaidRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.whole

    public static func document(
        content: String,
        isDark: Bool
    ) -> String {
        ReaderDocument.render(
            theme: .standard(isDark: isDark),
            title: "Galaxy Artifact Reader",
            css: """
            .mermaid-container {
                display: flex;
                justify-content: center;
                padding: 32px 16px;
                width: 100%;
            }
            .mermaid {
                width: 100%;
            }
            .mermaid svg {
                width: 100%;
                height: auto;
            }
            """,
            body: """
            <div class="mermaid-container">
            <pre class="mermaid">\(HTMLEscape.text(content))</pre>
            </div>
            """,
            // The diagram has to exist before the cards install, because a
            // whole-document anchor measures the rendered page.
            scriptsBeforeCards: """
            \(ReaderAssets.mermaidJS)
            if (typeof mermaid !== 'undefined') {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: '\(isDark ? "dark" : "default")',
                    securityLevel: 'loose',
                });
                mermaid.run();
            }
            """,
            cardScripts: .withoutAddNote
        )
    }
}
