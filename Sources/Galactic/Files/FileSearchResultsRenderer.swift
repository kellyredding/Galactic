import Foundation

/// Renders a search run as a page.
///
/// Modelled on the reference implementation's Find Results buffer, and on
/// `SourceRenderer` for the markup: the same two-column numbered rows and the
/// same sticky gutter, so jumping from a result into the file it names does not
/// change how a line looks.
///
/// **Ships no JavaScript.** Paths and line numbers are ordinary `<a>` elements
/// carrying a `SearchHitLink` href; `AnnotationCoordinator` cancels every link
/// navigation and hands ours to the host. That is why there is no
/// `// js-validate` marker in this file and no entry in
/// `ShippedJavaScriptTests` — there is nothing here that could fail only at
/// runtime inside a web view.
public enum FileSearchResultsRenderer {

    /// How this page is anchored.
    ///
    /// `.whole` rather than a line anchoring of its own, deliberately: the
    /// numbers in this gutter belong to *other* files, so a line jump inside
    /// this page would mean nothing. `ReaderLineJump.supports` is false for it,
    /// which is the correct answer rather than an omission.
    public static let anchoring = ReaderAnchoring.whole

    /// The yellow. The same value as the find bar's match highlight, so
    /// "this is what you were looking for" reads the same everywhere.
    ///
    /// A **different class name**, and that is load-bearing: the find module's
    /// `clear()` unwraps every `mark.galaxy-find-match` in the document, so
    /// reusing that name would make ⌘F strip the search highlighting the first
    /// time it was closed — silently, and only after the reader had used both
    /// features together.
    static let hitBackground = "rgba(255, 220, 50, 0.45)"

    public static func document(run: FileSearchRun, isDark: Bool) -> String {
        let theme = ReaderTheme.standard(isDark: isDark)

        return ReaderDocument.render(
            theme: theme,
            title: "Find Results",
            fontFamily: ReaderFont.mono,
            css: css(theme: theme, isDark: isDark),
            body: header(run: run) + files(run: run),
            // The send bar stays — it is set-wide, and a reader mid-review
            // should not watch it vanish because they searched. "Add a note"
            // goes: generated content is navigation, not something to annotate,
            // and a note anchored to a results line would outlive the results.
            cardScripts: .withoutAddNote
        )
    }

    // MARK: - The header

    /// What was searched, and everything the run has to admit.
    static func header(run: FileSearchRun) -> String {
        var lines: [String] = []

        if !run.wasRootIndexed {
            lines.append(
                "This folder is not indexed yet, so nothing was searched."
            )
        } else {
            let files = run.filesConsidered.formatted()
            let mode = run.query.isCaseSensitive
                ? "case sensitive" : "case insensitive"
            lines.append(
                "Searching \(files) files for "
                    + "\"\(HTMLEscape.text(run.query.text))\" (\(mode))"
            )
        }

        switch run.truncation {
        case .matchCap(let cap):
            lines.append(
                "Stopped at \(cap.formatted()) matches — "
                    + "\(run.filesScanned.formatted()) of "
                    + "\(run.filesConsidered.formatted()) files were read."
            )
        case .fileCap(let cap):
            lines.append(
                "Some files had more than \(cap.formatted()) matches; "
                    + "only the first \(cap.formatted()) of each are shown."
            )
        case nil:
            break
        }

        // Said here rather than left to the settings tab. A reader whose `log/`
        // has no matches would otherwise conclude the string is not there.
        if run.wasRootIndexed, !run.skippedNames.isEmpty {
            let names = run.skippedNames.map { HTMLEscape.text($0) }
                .joined(separator: ", ")
            lines.append("Not searched: \(names)")
        }

        if run.wasRootIndexed, run.files.isEmpty, run.truncation == nil {
            lines.append("No matches.")
        }

        return """
            <div class="results-header">
            \(lines.map { "<div>\($0)</div>" }.joined(separator: "\n"))
            </div>
            """
    }

    // MARK: - The files

    private static func files(run: FileSearchRun) -> String {
        run.files.map { file in
            let href = SearchHitLink.url(path: file.path)?.absoluteString ?? ""
            let count = file.matchCount == 1
                ? "1 match" : "\(file.matchCount.formatted()) matches"
            let more = file.wasTruncated ? "+" : ""

            let blocks = file.blocks.enumerated().map { index, block in
                let rows = block.map { row(line: $0, path: file.path) }
                    .joined(separator: "\n")
                // A gap between blocks is a gap in the file, and it is drawn
                // rather than implied — two runs of numbers butted together
                // read as one continuous passage.
                let spacer = index == 0
                    ? ""
                    : "<tr class=\"result-gap\"><td colspan=\"2\">"
                        + "&nbsp;</td></tr>\n"
                return spacer + rows
            }.joined(separator: "\n")

            return """
                <div class="result-file">
                <div class="result-path-line">
                <a class="result-path" href="\(HTMLEscape.text(href))">\
                \(HTMLEscape.text(file.relativePath))</a>\
                <span class="result-count">\(count)\(more)</span>
                </div>
                <table class="result-table"><tbody>
                \(blocks)
                </tbody></table>
                </div>
                """
        }.joined(separator: "\n")
    }

    private static func row(line: FileSearchLine, path: String) -> String {
        let content = line.segments.map { segment in
            segment.isMatch
                ? "<mark class=\"search-hit\">"
                    + HTMLEscape.text(segment.text) + "</mark>"
                : HTMLEscape.text(segment.text)
        }.joined()

        // The colon marks a matching line, following the reference
        // implementation. Only a matching line's number is a link, because only
        // it is a place worth landing on.
        let number: String
        if line.isMatch,
            let href = SearchHitLink.url(path: path, line: line.line)?
                .absoluteString
        {
            number = "<a class=\"result-line-num\" "
                + "href=\"\(HTMLEscape.text(href))\">\(line.line)</a>:"
        } else {
            number = "\(line.line)"
        }

        return "<tr class=\"result-line\(line.isMatch ? " is-match" : "")\">"
            + "<td class=\"line-num\">\(number)</td>"
            + "<td class=\"line-content\">"
            + (content.isEmpty ? "&nbsp;" : content)
            + "</td></tr>"
    }

    // MARK: - Style

    private static func css(theme: ReaderTheme, isDark: Bool) -> String {
        """
        body { padding: 0 0 24px 0; }
        .results-header {
            padding: 12px 16px;
            color: \(theme.mutedForeground);
            border-bottom: 1px solid \(theme.border);
            line-height: 1.6;
            white-space: pre-wrap;
        }
        .result-file { margin-top: 18px; }
        .result-path-line {
            padding: 0 16px 4px 16px;
            display: flex;
            gap: 10px;
            align-items: baseline;
        }
        a.result-path {
            color: \(theme.accent);
            text-decoration: none;
            /* Without this, a selection starting on a link becomes a URL drag
               and never yields a mouseup with a range — the trap
               MarkdownRenderer's stylesheet already carries this line for. */
            -webkit-user-drag: none;
        }
        a.result-path:hover { text-decoration: underline; }
        .result-count {
            color: \(theme.mutedForeground);
            font-size: 11px;
        }
        table.result-table {
            border-collapse: collapse;
            width: max-content;
            min-width: 100%;
        }
        .result-line td, .result-gap td {
            padding: 0;
            vertical-align: top;
            white-space: pre;
        }
        .line-num {
            width: 6em;
            min-width: 6em;
            max-width: 6em;
            text-align: right;
            padding-right: 12px !important;
            padding-left: 8px !important;
            color: \(theme.lineNumber);
            background: \(theme.gutter);
            user-select: none;
            -webkit-user-select: none;
            border-right: 1px solid \(isDark ? "#21262d" : "#d0d7de");
            position: sticky;
            left: 0;
            z-index: 1;
        }
        a.result-line-num {
            color: \(theme.accent);
            text-decoration: none;
            -webkit-user-drag: none;
        }
        a.result-line-num:hover { text-decoration: underline; }
        .line-content {
            padding-left: 12px !important;
            padding-right: 16px !important;
        }
        .result-line.is-match .line-content { color: \(theme.foreground); }
        .result-line:not(.is-match) .line-content {
            color: \(theme.mutedForeground);
        }
        .result-gap .line-num { border-right-color: transparent; }
        mark.search-hit {
            background: \(Self.hitBackground);
            color: inherit;
            padding: 0;
            border-radius: 1px;
        }
        """
    }
}
