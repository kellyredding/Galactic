import Foundation
import Markdown

/// Renders markdown as a page, anchored to its source lines.
public enum MarkdownRenderer {
    /// How this renderer's markup is anchored.
    ///
    /// One `.md-block` can span several source lines — a fenced block, a table
    /// row — so the span needs a pair of attributes rather than one.
    public static let anchoring = ReaderAnchoring.lines(
        selector: ".md-block",
        lineAttr: "data-line-start",
        endLineAttr: "data-line-end"
    )

    public static func document(
            markdown: String,
            isDark: Bool
        ) -> String {
        let document = MarkdownDocument.parse(markdown)
        var visitor = MarkdownHTMLVisitor()
        let bodyHTML = visitor.visit(document)

        let hjsContent = ReaderAssets.highlightJS
        let themeCSS = ReaderAssets.highlightThemeCSS(isDark: isDark)

        return buildFullHTML(
            bodyHTML: bodyHTML,
            highlightJS: hjsContent,
            highlightCSS: themeCSS,
            isDark: isDark
        )
    }

    // emojiDataJS and emojiAutocompleteJS are in
    // AnnotationSupport.swift


    /// Build a complete HTML document with embedded styles, highlight.js,
    /// and the AnnotationManager JavaScript module.
    static func buildFullHTML(
        bodyHTML: String,
        highlightJS: String,
        highlightCSS: String,
        isDark: Bool
    ) -> String {
        let theme = ReaderTheme.standard(isDark: isDark)

        return ReaderDocument.render(
            theme: theme,
            fontSize: "14px",
            lineHeight: "1.6",
            css: """
            /* Four properties this reader's rules use that the shared card
               variables do not define. Derived from the palette rather than
               restated, so a change to the border colour reaches all three of
               the places that borrow it. */
            :root {
                color-scheme: light dark;
                --blockquote-border: \(theme.border);
                --table-border: \(theme.border);
                --link-color: \(theme.accent);
                --hr-color: \(theme.border);
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                             Helvetica, Arial, sans-serif;
                font-size: 14px;
                line-height: 1.6;
                color: var(--fg);
                background: var(--bg);
                padding: 16px 24px;
                margin: 0;
                -webkit-font-smoothing: antialiased;
            }
            h1, h2, h3, h4, h5, h6 {
                margin-top: 24px;
                margin-bottom: 16px;
                font-weight: 600;
                line-height: 1.25;
            }
            h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--hr-color); }
            h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--hr-color); }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1em; }
            h5 { font-size: 0.875em; }
            h6 { font-size: 0.85em; color: var(--blockquote-fg); }
            p { margin-top: 0; margin-bottom: 16px; }
            /* -webkit-user-drag: none because a selection that begins on a
               link would otherwise start a URL drag instead. Selection
               capture is a document-level mouseup handler with no mousedown
               counterpart, so a drag produces no selection, no mouseup with a
               range, and no annotation toolbar — a passage starting with a
               URL would silently refuse to be annotated. */
            a {
              color: var(--link-color);
              text-decoration: none;
              -webkit-user-drag: none;
            }
            a:hover { text-decoration: underline; }
            code {
                font-family: "SF Mono", "Menlo", "Monaco", "Courier New", monospace;
                font-size: 85%;
                background: var(--code-bg);
                border-radius: 6px;
                padding: 0.2em 0.4em;
            }
            pre {
                background: var(--code-bg);
                border: 1px solid var(--code-border);
                border-radius: 6px;
                padding: 16px;
                overflow-x: auto;
                margin-top: 0;
                margin-bottom: 16px;
                line-height: 1.45;
            }
            pre code {
                background: none;
                padding: 0;
                font-size: 85%;
                border-radius: 0;
            }

            /* Code block line-level annotation support */
            .code-line {
                margin: 0;
                padding: 0;
                line-height: 1.45;
            }
            .code-line code,
            .code-line code.hljs {
                display: inline;
                background: none;
                padding: 0;
                border-radius: 0;
                font-size: 85%;
                white-space: pre;
            }
            .code-line.annotation-highlight {
                background-color: rgba(88, 166, 255, 0.12);
                border-left: 3px solid
                    rgba(88, 166, 255, 0.6);
                padding-left: 8px;
                margin-left: -11px;
            }
            .code-line.annotation-expanded-highlight {
                background-color: rgba(210, 153, 34, 0.10);
                border-left: 3px solid
                    rgba(210, 153, 34, 0.6);
                padding-left: 8px;
                margin-left: -11px;
            }

            /* Table row annotation support */
            tr.md-block.annotation-highlight td,
            tr.md-block.annotation-highlight th {
                background-color: rgba(88, 166, 255, 0.12);
            }
            tr.md-block.annotation-highlight td:first-child,
            tr.md-block.annotation-highlight th:first-child {
                border-left: 3px solid
                    rgba(88, 166, 255, 0.6);
            }
            tr.md-block.annotation-expanded-highlight td,
            tr.md-block.annotation-expanded-highlight th {
                background-color: rgba(210, 153, 34, 0.10);
            }
            tr.md-block.annotation-expanded-highlight
                td:first-child,
            tr.md-block.annotation-expanded-highlight
                th:first-child {
                border-left: 3px solid
                    rgba(210, 153, 34, 0.6);
            }

            .mermaid {
                text-align: center;
                margin-bottom: 16px;
                overflow-x: auto;
            }
            .mermaid svg {
                max-width: 100%;
                height: auto;
            }
            blockquote {
                margin: 0 0 16px 0;
                padding: 0 1em;
                color: var(--blockquote-fg);
                border-left: 0.25em solid var(--blockquote-border);
            }
            ul, ol { margin-top: 0; margin-bottom: 16px; padding-left: 2em; }
            li + li { margin-top: 0.25em; }
            table {
                border-spacing: 0;
                border-collapse: collapse;
                margin-top: 0;
                margin-bottom: 16px;
                width: auto;
            }
            th, td {
                padding: 6px 13px;
                border: 1px solid var(--table-border);
            }
            th {
                font-weight: 600;
                background: var(--table-header-bg);
            }
            hr {
                height: 0.25em;
                padding: 0;
                margin: 24px 0;
                background-color: var(--hr-color);
                border: 0;
                border-radius: 2px;
            }
            img { max-width: 100%; }
            .md-block { /* Line-anchored block wrapper — no visual styling */ }
            \(highlightCSS)
            """,
            body: """
            \(bodyHTML)
            """,
            scriptsBeforeCards: """
            \(highlightJS)
            if (typeof hljs !== 'undefined') hljs.highlightAll();
            """,
            // Diagrams render after the cards install. Unlike the standalone
            // diagram reader, a fence here is one block among many and the
            // anchors around it do not depend on its final size.
            scriptsAfterCards: """
            \(ReaderAssets.mermaidJS)
            if (typeof mermaid !== 'undefined'
                && document.querySelector('.mermaid')) {
                mermaid.initialize({
                    startOnLoad: false,
                    theme: \(isDark ? "'dark'" : "'default'"),
                    securityLevel: 'loose',
                });
                mermaid.run();
            }
            """
        )
    }
}
