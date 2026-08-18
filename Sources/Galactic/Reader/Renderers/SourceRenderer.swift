import Foundation

/// Renders source text as numbered, syntax-highlighted lines.
///
/// The fallback for any file kind without a reader of its own, which is why
/// the language is optional: an unrecognised extension still renders, just
/// without colour.
public enum SourceRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.lines(selector: ".code-line")


    /// The highlighting pass, as one language-free constant.
    ///
    /// Separate from the document so it is a *value* — `ShippedJavaScriptTests`
    /// parses everything this package ships, and it can only parse what it can
    /// name. Built inline it was neither named nor parsed, which is the state the
    /// apps' own gates exist to prevent and cannot see into.
    ///
    /// ### Highlighted once, then distributed
    ///
    /// A row is not a unit of syntax. Highlighting each one alone cannot see a
    /// block comment, a multi-line string, or a fence inside a markdown file read
    /// as source, because the construct that opens on one row closes on another
    /// and neither row knows about the other. It is also N calls into a grammar
    /// where one would do, over a document that can be twenty thousand rows.
    ///
    /// The document has exactly one language — the host resolved it from the
    /// filename — so there is nothing per-row to decide. That is the difference
    /// from `MarkdownRenderer`, which highlights each fenced block separately
    /// *because* each fence names its own language, and is deliberately left
    /// alone.
    ///
    /// ### Why it checks itself
    ///
    /// Splitting highlighted markup back into rows means re-opening the spans
    /// that straddle a newline, and getting that wrong shows as scrambled markup
    /// rather than as an error. So the split is verified against the row count
    /// before any row is written, and every unexpected answer — a mismatch, a
    /// throw, an unregistered language — falls back to the per-row pass this
    /// replaced. That fallback is the previous behaviour exactly, which bounds
    /// what a mistake in here can cost to what it already cost.
    static let highlightJS = """
        // Close every open span at a newline and re-open them after it, so each
        // row is standalone markup. A stack, because spans nest.
        function galaxySplitLines(html) {
            var lines = [];
            var open = [];
            var current = "";
            var i = 0;
            while (i < html.length) {
                if (html[i] === "<") {
                    var end = html.indexOf(">", i);
                    if (end === -1) { current += html.slice(i); break; }
                    var tag = html.slice(i, end + 1);
                    if (tag.indexOf("</") === 0) {
                        open.pop();
                    } else if (tag.indexOf("<span") === 0) {
                        open.push(tag);
                    }
                    current += tag;
                    i = end + 1;
                    continue;
                }
                if (html[i] === "\\n") {
                    for (var c = 0; c < open.length; c++) {
                        current += "</span>";
                    }
                    lines.push(current);
                    current = open.join("");
                    i += 1;
                    continue;
                }
                current += html[i];
                i += 1;
            }
            lines.push(current);
            return lines;
        }

        // What this replaced, kept as the fallback for every case the pass below
        // declines to handle.
        function galaxyHighlightPerLine(cells, language) {
            cells.forEach(function(el) {
                el.classList.add("language-" + language);
                hljs.highlightElement(el);
            });
        }

        function galaxyHighlightSource(language) {
            if (typeof hljs === "undefined") { return; }
            // An unregistered name is worse than none: hljs answers one by
            // auto-detecting, which is the behaviour being escaped.
            if (!language || !hljs.getLanguage(language)) { return; }

            var cells = Array.prototype.slice.call(
                document.querySelectorAll(".line-content")
            );
            if (cells.length === 0) { return; }

            // Reassembled from the rows rather than shipped a second time. The
            // table already holds every line, and embedding the source again
            // would double the page's text for a document that can be large.
            var source = cells.map(function(el) {
                return el.textContent;
            }).join("\\n");

            try {
                var result = hljs.highlight(source, {
                    language: language,
                    ignoreIllegals: true
                });
                var lines = galaxySplitLines(result.value);
                if (lines.length !== cells.length) {
                    galaxyHighlightPerLine(cells, language);
                    return;
                }
                for (var i = 0; i < cells.length; i++) {
                    cells[i].innerHTML = lines[i] === "" ? "&nbsp;" : lines[i];
                    cells[i].classList.add("hljs");
                }
            } catch (e) {
                galaxyHighlightPerLine(cells, language);
            }
        }
        """

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

        // The class the *lines* carry, not the table. See the script below for
        // why that distinction was the whole bug.
        let langClass =
            language != nil
            ? "language-\(language!)"
            : "nohighlight"
        let jsLanguage = language ?? ""

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
            \(highlightJS)
            galaxyHighlightSource("\(jsLanguage)");
            """
        )
    }
}
