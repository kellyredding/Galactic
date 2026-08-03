import Foundation

/// Renders an HTML file, whether or not it brought its own document.
///
/// The one renderer with two paths. Content arriving as a fragment is wrapped
/// in a page built here; content arriving with its own `<html>` is left as its
/// author wrote it and has the annotation layer spliced into it instead.
///
/// The second path exists because rebuilding such a page would mean discarding
/// the author's own head — their stylesheet, their fonts, their title — to gain
/// a frame they had already provided. It takes the annotation styles and the
/// card scripts from `ReaderDocument` rather than restating them, which is the
/// only way the two paths stay in step.
///
/// Blocks are indexed by walking the rendered DOM rather than during
/// generation, because in neither path does this renderer know the structure:
/// one is arbitrary authored markup and the other is a fragment of it.
public enum HTMLRenderer {
    /// How this renderer's markup is anchored.
    public static let anchoring = ReaderAnchoring.blocks(
        selector: ".annotatable-block"
    )

    // MARK: - DOM Walk Block Index JS

    /// JS that walks the DOM and assigns
    /// data-block-index + annotatable-block class to
    /// block-level elements. Must run after page load,
    /// before AnnotationManager.initialize().
    // js-validate
    static let blockIndexDOMWalkJS: String = """
    (function() {
        // Leaf selectors — the actual annotatable
        // units. Note: <pre> is NOT in this list;
        // it gets split into per-line divs below.
        var leafSel = 'p,h1,h2,h3,h4,h5,h6,li,tr,' +
            'figcaption,dt,dd';
        var index = 1;

        function tagBlock(el) {
            el.setAttribute('data-block-index', index);
            el.classList.add('annotatable-block');
            index++;
        }

        document.querySelectorAll(leafSel)
            .forEach(function(el) {
                if (el.closest('[data-block-index]'))
                    return;
                tagBlock(el);
            });

        // Split <pre> blocks into per-line divs so
        // each line is independently annotatable.
        document.querySelectorAll('pre')
            .forEach(function(pre) {
                if (pre.closest('[data-block-index]'))
                    return;
                var code = pre.querySelector('code');
                var src = code
                    ? code.textContent
                    : pre.textContent;
                var lines = src.split('\\n');
                // Drop trailing empty line from
                // trailing newline
                if (lines.length > 0
                    && lines[lines.length - 1] === '')
                {
                    lines.pop();
                }
                // Clear existing content
                pre.innerHTML = '';
                pre.classList.add('code-block-wrapper');
                lines.forEach(function(line) {
                    var div = document.createElement(
                        'div'
                    );
                    div.className =
                        'annotatable-block code-line';
                    var codeEl = document.createElement(
                        'code'
                    );
                    codeEl.textContent =
                        line || '\\u00A0';
                    div.appendChild(codeEl);
                    tagBlock(div);
                    pre.appendChild(div);
                });
            });
    })()
    """

    // MARK: - HTML Wrapping

    // MARK: - Theme-Aware Base Stylesheet

    /// Provides sensible dark/light defaults for common
    /// HTML elements so artifacts don't need to be
    /// theme-aware. Uses CSS vars from annotationCSSVars
    /// plus additional vars for borders, links, and HRs.
    /// Injected AFTER artifact styles so cascade order
    /// wins for equal-specificity selectors.
    static func htmlBaseCSS(isDark: Bool) -> String {
        let blockquoteBorder = isDark
            ? "#555" : "#ddd"
        let tableBorder = isDark
            ? "#444" : "#ddd"
        let linkColor = isDark
            ? "#58a6ff" : "#0969da"
        let hrColor = isDark
            ? "#444" : "#d0d7de"

        return """
        /* Galaxy theme-aware base styles */
        :root {
            --blockquote-border: \(blockquoteBorder);
            --table-border: \(tableBorder);
            --link-color: \(linkColor);
            --hr-color: \(hrColor);
        }
        html, body {
            background: var(--bg);
            color: var(--fg);
            font-family: -apple-system, BlinkMacSystemFont,
                "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 16px;
            font-weight: 600;
            line-height: 1.25;
            color: var(--fg);
        }
        h1 {
            font-size: 2em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--hr-color);
        }
        h2 {
            font-size: 1.5em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--hr-color);
        }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; }
        h6 {
            font-size: 0.85em;
            color: var(--blockquote-fg);
        }
        p { margin-top: 0; margin-bottom: 16px; }
        a {
            color: var(--link-color);
            text-decoration: none;
        }
        a:hover { text-decoration: underline; }
        code {
            font-family: "SF Mono", "Menlo", "Monaco",
                "Courier New", monospace;
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
        blockquote {
            margin: 0 0 16px 0;
            padding: 0 1em;
            color: var(--blockquote-fg);
            border-left: 0.25em solid
                var(--blockquote-border);
        }
        ul, ol {
            margin-top: 0;
            margin-bottom: 16px;
            padding-left: 2em;
        }
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
        img { max-width: 100%; height: auto; }
        """
    }

    /// If the HTML already has a full document structure,
    /// inject our annotation infrastructure. Otherwise,
    /// wrap it in a minimal themed shell.
    public static func document(
        content: String,
        isDark: Bool
    ) -> String {
        let theme = ReaderTheme.standard(isDark: isDark)

        let lower = content.lowercased()

        // If it already has <html> or <!doctype>, inject
        // our scripts into the existing document.
        if lower.contains("<html")
            || lower.contains("<!doctype")
        {
            // Inject CSS vars and annotation styles before
            // </head>, and scripts before </body>
            var html = content

            let baseCSS = htmlBaseCSS(isDark: isDark)
            // Two style elements, not one: the reader's own rules, then the
            // annotation layer complete with the variables it reads. The layer
            // arrives as a unit from the engine so this branch cannot take half
            // of it — which it did, and the cards rendered as white boxes.
            let styleBlock = """
            <style>
            \(baseCSS)
            \(htmlAnnotationAdaptCSS)
            </style>
            \(ReaderDocument.annotationStyleTag(theme: theme))
            """
            // The same run, in the same order, that a rebuilt document gets.
            let scriptBlock = """
            <script>\(blockIndexDOMWalkJS)</script>
            \(ReaderDocument.cardScriptTags(.full))
            """

            if let headEnd = html.range(
                of: "</head>",
                options: .caseInsensitive
            ) {
                html.insert(
                    contentsOf: styleBlock,
                    at: headEnd.lowerBound
                )
            }
            if let bodyEnd = html.range(
                of: "</body>",
                options: .caseInsensitive
            ) {
                html.insert(
                    contentsOf: scriptBlock,
                    at: bodyEnd.lowerBound
                )
            }
            return html
        }

        // Otherwise wrap in a themed shell
        let baseCSS = htmlBaseCSS(isDark: isDark)
        return ReaderDocument.render(
            theme: theme,
            title: "Galaxy Artifact Reader",
            css: """
            \(baseCSS)
            \(htmlAnnotationAdaptCSS)
            """,
            body: """
            \(content)
            """,
            scriptsBeforeCards: blockIndexDOMWalkJS
        )
    }

    /// Rules adapting the annotation layer to arbitrary host markup.
    ///
    /// Shared by both branches of `wrapHTML`. A document that arrives with its
    /// own `<html>` has these spliced into it; one that does not gets them in
    /// the shell built around it. They were written twice, identically, and the
    /// two copies were seventy lines apart in the same function.
    static let htmlAnnotationAdaptCSS: String = """
    /* Code block line-level annotation support */
        .code-block-wrapper {
            margin: 0;
            padding: 16px;
        }
        .code-line {
            margin: 0;
            padding: 0;
            line-height: 1.45;
        }
        .code-line code {
            display: inline;
            background: none;
            padding: 0;
            border-radius: 0;
            white-space: pre;
        }
        .code-line.annotation-highlight {
            background-color:
                rgba(88, 166, 255, 0.12);
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
            padding-left: 8px;
            margin-left: -11px;
        }
        .code-line.annotation-expanded-highlight {
            background-color:
                var(--annotation-active-block-bg);
            border-left: 3px solid
                var(--annotation-active-block-border);
            padding-left: 8px;
            margin-left: -11px;
        }
        /* Annotation highlight for blocks */
        .annotatable-block.annotation-highlight {
            background-color:
                rgba(88, 166, 255, 0.12);
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
            padding-left: 8px;
            margin-left: -11px;
        }
        .annotatable-block.annotation-expanded-highlight {
            background-color:
                var(--annotation-active-block-bg);
            border-left: 3px solid
                var(--annotation-active-block-border);
            padding-left: 8px;
            margin-left: -11px;
        }
        tr.annotatable-block.annotation-highlight td,
        tr.annotatable-block.annotation-highlight th {
            background-color:
                rgba(88, 166, 255, 0.12);
        }
        tr.annotatable-block.annotation-highlight
            td:first-child,
        tr.annotatable-block.annotation-highlight
            th:first-child {
            border-left: 3px solid
                rgba(88, 166, 255, 0.6);
        }
        tr.annotatable-block.annotation-expanded-highlight td,
        tr.annotatable-block.annotation-expanded-highlight th {
            background-color:
                var(--annotation-active-block-bg);
        }
        tr.annotatable-block.annotation-expanded-highlight td:first-child,
        tr.annotatable-block.annotation-expanded-highlight th:first-child {
            border-left: 3px solid
                var(--annotation-active-block-border);
        }

    """
}
