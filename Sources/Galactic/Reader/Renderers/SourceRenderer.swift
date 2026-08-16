import Foundation

/// Renders source text as numbered, syntax-highlighted lines.
///
/// The fallback for any file kind without a reader of its own, which is why
/// the language is optional: an unrecognised extension still renders, just
/// without colour.
public enum SourceRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.lines(selector: ".code-line")

    public static func document(
        content: String,
        language: String?,
        isDark: Bool
    ) -> String {
        let hjsContent = ReaderAssets.highlightJS
        let themeCSS = ReaderAssets.highlightThemeCSS(
            isDark: isDark
        )

        let theme = ReaderTheme.standard(isDark: isDark)

        // Build line-numbered code block
        let lines = content.components(separatedBy: "\n")
        var lineHTML = ""
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            let escapedLine = HTMLEscape.text(line)
            lineHTML +=
                "<tr class=\"code-line\""
                + " data-line=\"\(lineNum)\">"
                + "<td class=\"line-num\">\(lineNum)</td>"
                + "<td class=\"line-content\">"
                + "\(escapedLine.isEmpty ? " " : escapedLine)"
                + "</td></tr>\n"
        }

        let langClass =
            language != nil
            ? "language-\(language!)"
            : "nohighlight"

        return ReaderDocument.render(
            theme: theme,
            fontFamily: ReaderFont.mono,
            css: """
            .source-container {
                width: 100%;
                overflow-x: auto;
            }
            table.source-table {
                border-collapse: collapse;
                width: max-content;
                min-width: 100%;
            }
            .code-line td {
                padding: 0 0;
                vertical-align: top;
                white-space: pre;
            }
            .line-num {
                width: 4em;
                min-width: 4em;
                max-width: 4em;
                text-align: right;
                padding-right: 12px !important;
                padding-left: 8px !important;
                color: \(theme.lineNumber);
                background: \(theme.gutter);
                user-select: none;
                -webkit-user-select: none;
                border-right: 1px solid
                    \(isDark ? "#21262d" : "#d0d7de");
                position: sticky;
                left: 0;
                z-index: 1;
            }
            .line-content {
                padding-left: 12px !important;
                padding-right: 16px !important;
            }
            /* Override hljs background — we handle it */
            .hljs { background: transparent !important; }
            /* Annotation highlight adaption for table rows */
            .code-line.annotation-highlight td {
                background-color: rgba(88, 166, 255, 0.12);
            }
            .code-line.annotation-highlight .line-num {
                border-left: 3px solid
                    rgba(88, 166, 255, 0.6);
                padding-left: 5px !important;
            }
            .code-line.annotation-expanded-highlight td {
                background-color:
                    var(--annotation-active-block-bg);
            }
            .code-line.annotation-expanded-highlight .line-num {
                border-left: 3px solid
                    var(--annotation-active-block-border);
                padding-left: 5px !important;
            }
            \(themeCSS)
            """,
            body: """
            <div class="source-container">
            <table class="source-table">
            <tbody class="\(langClass)">
            \(lineHTML)
            </tbody>
            </table>
            </div>
            """,
            // Highlight before the cards install: the manager measures the
            // rows it anchors to, and highlighting rewrites their contents.
            scriptsBeforeCards: """
            \(hjsContent)
            if (typeof hljs !== 'undefined') {
                document.querySelectorAll('.line-content')
                    .forEach(function(el) {
                        hljs.highlightElement(el);
                    });
            }
            """
        )
    }
}
