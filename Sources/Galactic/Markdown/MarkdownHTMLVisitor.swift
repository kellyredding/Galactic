import Foundation
import Markdown

/// Emits line-anchored HTML from a parsed markdown document.
///
/// Every block carries the source lines it came from, so an annotation written
/// against the rendered page can be stored against the text that produced it
/// and found again after a re-render. That is the whole reason this visitor
/// exists rather than any off-the-shelf renderer: the anchoring has to survive
/// the round trip, and only the parse knows where a block began.
///
/// One of two emitters over the same parse — see `MarkdownDocument`.
///
/// Internal: the public door is `MarkdownRenderer.document`. Conforming to a
/// public protocol would otherwise oblige every visit method to be public
/// too, publishing thirty-odd members nothing outside this package calls.
struct MarkdownHTMLVisitor: MarkupVisitor {
    typealias Result = String

    /// Tracks table nesting so list items inside table cells emit bare
    /// `<li>` (no md-block class) — the table row is the navigable unit.
    private var insideTable: Bool = false

    // MARK: - Default / Document

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    // MARK: - Block Elements (line-anchored)

    func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = visitChildren(paragraph)
        return wrapBlock("p", markup: paragraph, inner: inner)
    }

    func visitHeading(_ heading: Heading) -> String {
        let tag = "h\(heading.level)"
        let inner = visitChildren(heading)
        return wrapBlock(tag, markup: heading, inner: inner)
    }

    func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // Mermaid code blocks render as diagrams
        // (not line-annotatable)
        if codeBlock.language?.lowercased()
            == "mermaid"
        {
            let escaped = HTMLEscape.text(codeBlock.code)
            let inner = "<div class=\"mermaid\">"
                + "\(escaped)</div>"
            return wrapBlock(
                "div", markup: codeBlock,
                inner: inner
            )
        }

        let langAttr: String
        if let lang = codeBlock.language,
           !lang.isEmpty
        {
            langAttr = " class=\"language-"
                + "\(HTMLEscape.text(lang))\""
        } else {
            langAttr = ""
        }

        // Content lines start after the opening
        // fence (```). Each line becomes its own
        // md-block so it can be individually
        // selected and annotated.
        let fenceStart =
            codeBlock.range?.lowerBound.line ?? 0
        let contentStartLine = fenceStart + 1

        var lines = codeBlock.code.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        // Drop trailing empty line from fence
        // parsing
        if let last = lines.last, last.isEmpty {
            lines = lines.dropLast()
        }

        var linesDivs = ""
        for (idx, line) in lines.enumerated() {
            let lineNum = contentStartLine + idx
            let raw = String(line)
            // Empty lines need &nbsp; so the div
            // maintains its line height instead of
            // collapsing to zero.
            let content = raw.isEmpty
                ? "&nbsp;"
                : HTMLEscape.text(raw)
            linesDivs += "<div class=\"md-block"
                + " code-line\""
                + " data-line-start=\"\(lineNum)\""
                + " data-line-end=\"\(lineNum)\">"
                + "<code\(langAttr)>\(content)"
                + "</code></div>"
        }

        // Outer <pre> provides visual code block
        // styling but is NOT an md-block — the
        // individual code-line divs inside are
        // the selectable annotation units.
        let fenceEnd =
            codeBlock.range?.upperBound.line ?? 0
        return "<pre class=\"code-block-wrapper\""
            + " data-line-start=\"\(fenceStart)\""
            + " data-line-end=\"\(fenceEnd)\">"
            + "\(linesDivs)</pre>\n"
    }

    func visitBlockQuote(
        _ blockQuote: BlockQuote
    ) -> String {
        // Children (paragraphs, lists, etc.) are
        // already wrapped as their own md-blocks by
        // their respective visit methods. The outer
        // <blockquote> provides visual styling but
        // is NOT an md-block — the children inside
        // are the selectable annotation units.
        let inner = visitChildren(blockQuote)
        let start =
            blockQuote.range?.lowerBound.line ?? 0
        let end =
            blockQuote.range?.upperBound.line ?? 0
        return "<blockquote"
            + " data-line-start=\"\(start)\""
            + " data-line-end=\"\(end)\">"
            + "\(inner)</blockquote>\n"
    }

    func visitOrderedList(_ orderedList: OrderedList) -> String {
        let inner = visitChildren(orderedList)
        return wrapBlock("ol", markup: orderedList, inner: inner)
    }

    func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let inner = visitChildren(unorderedList)
        return wrapBlock("ul", markup: unorderedList, inner: inner)
    }

    func visitListItem(_ listItem: ListItem) -> String {
        let inner = visitChildren(listItem)
        if insideTable {
            return "<li>\(inner)</li>\n"
        }
        return wrapBlock("li", markup: listItem, inner: inner)
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        return lineAttrs(thematicBreak, tag: "hr")
    }

    func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return wrapBlock("div", markup: html, inner: html.rawHTML)
    }

    mutating func visitTable(
        _ table: Markdown.Table
    ) -> String {
        insideTable = true

        // Each row becomes its own md-block so it
        // can be individually annotated. The outer
        // <table> wrapper provides visual styling
        // but is NOT an md-block.
        var html = "<table>\n"

        // Header row as its own md-block <tr>
        let headAttrs = lineAttrsString(table.head)
        html += "<thead><tr\(headAttrs)>"
        for cell in table.head.cells {
            html += "<th>"
                + "\(visitChildren(cell))</th>"
        }
        html += "</tr></thead>\n"

        // Body rows — each as its own md-block <tr>
        html += "<tbody>\n"
        for row in table.body.rows {
            let rowAttrs = lineAttrsString(row)
            html += "<tr\(rowAttrs)>"
            for cell in row.cells {
                html += "<td>"
                    + "\(visitChildren(cell))"
                    + "</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n"
        html += "</table>\n"

        insideTable = false

        // Outer div is NOT an md-block — the
        // individual <tr> rows inside are the
        // selectable annotation units.
        let start =
            table.range?.lowerBound.line ?? 0
        let end =
            table.range?.upperBound.line ?? 0
        return "<div class=\"table-wrapper\""
            + " data-line-start=\"\(start)\""
            + " data-line-end=\"\(end)\">"
            + "\(html)</div>\n"
    }

    // MARK: - Inline Elements

    /// Plain text, with any bare URL in it linked.
    ///
    /// The sibling emitter has done this since autolinking arrived; this side
    /// deliberately did not, because a reader has annotation and text
    /// selection to answer for where a tooltip does not. Both are answered
    /// now — annotations anchor to source lines rather than DOM positions, so
    /// an added element cannot strand one, and the stylesheet suppresses the
    /// link drag that would otherwise swallow a selection.
    ///
    /// Escaping runs over each piece separately rather than over the whole
    /// string once: the anchor's markup must survive, and the text on either
    /// side of it must not.
    func visitText(_ text: Markdown.Text) -> String {
        let source = text.string

        // A link's own label is already inside a link, so autolinking it
        // would nest one address in another. Mostly invisible, because
        // `visitLink` supplies the authored destination — but not when there
        // is none to supply: `[https://shown.example]()` says explicitly that
        // this text goes nowhere, and without this guard it would go to
        // itself.
        guard !isInsideLink(text) else {
            return HTMLEscape.text(source)
        }

        let spans = MarkdownAutolink.spans(in: source)
        guard !spans.isEmpty else {
            return HTMLEscape.text(source)
        }

        var html = ""
        var cursor = source.startIndex
        for span in spans {
            html += HTMLEscape.text(
                String(source[cursor..<span.range.lowerBound])
            )
            let shown = String(source[span.range])
            html += "<a href=\"\(HTMLEscape.text(span.url.absoluteString))\">"
                + HTMLEscape.text(shown)
                + "</a>"
            cursor = span.range.upperBound
        }
        html += HTMLEscape.text(String(source[cursor...]))
        return html
    }

    /// Walked rather than tracked, because emphasis and strong nest in
    /// between: the text of `[**https://example.com**](…)` has a `Strong` for
    /// a parent, not the `Link`.
    ///
    /// Stateless on purpose. `visitChildren` copies the visitor per call
    /// (`var visitor = self`) and `visitLink` is non-mutating, so a flag set
    /// on descent is subtle to get right here; an ancestor walk cannot be
    /// wrong about it. Mirrors `MarkdownAttributedVisitor.isInsideLink`.
    private func isInsideLink(_ markup: any Markup) -> Bool {
        var ancestor = markup.parent
        while let node = ancestor {
            if node is Link { return true }
            ancestor = node.parent
        }
        return false
    }

    func visitEmphasis(_ emphasis: Emphasis) -> String {
        return "<em>\(visitChildren(emphasis))</em>"
    }

    func visitStrong(_ strong: Strong) -> String {
        return "<strong>\(visitChildren(strong))</strong>"
    }

    func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        return "<del>\(visitChildren(strikethrough))</del>"
    }

    func visitInlineCode(_ inlineCode: InlineCode) -> String {
        return "<code>\(HTMLEscape.text(inlineCode.code))</code>"
    }

    func visitLink(_ link: Markdown.Link) -> String {
        let dest = link.destination ?? ""
        return "<a href=\"\(HTMLEscape.text(dest))\">\(visitChildren(link))</a>"
    }

    func visitImage(_ image: Markdown.Image) -> String {
        let src = image.source ?? ""
        let alt = image.plainText
        return "<img src=\"\(HTMLEscape.text(src))\" alt=\"\(HTMLEscape.text(alt))\">"
    }

    func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        return "\n"
    }

    func visitLineBreak(_ lineBreak: LineBreak) -> String {
        return "<br>\n"
    }

    func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        return inlineHTML.rawHTML
    }

    // MARK: - Helpers

    /// Visit all children and concatenate their results.
    private func visitChildren(_ markup: any Markup) -> String {
        var visitor = self
        var result = ""
        for child in markup.children {
            result += visitor.visit(child)
        }
        return result
    }

    /// Wrap content in a block tag with line anchor attributes.
    private func wrapBlock(_ tag: String, markup: any Markup, inner: String) -> String {
        let attrs = lineAttrsString(markup)
        return "<\(tag)\(attrs)>\(inner)</\(tag)>\n"
    }

    /// Generate a self-closing tag with line attributes (e.g., <hr>).
    private func lineAttrs(_ markup: any Markup, tag: String) -> String {
        let attrs = lineAttrsString(markup)
        return "<\(tag)\(attrs)>\n"
    }

    /// Build the data-line-start/data-line-end attribute string.
    private func lineAttrsString(_ markup: any Markup) -> String {
        guard let range = markup.range else { return " class=\"md-block\"" }
        let start = range.lowerBound.line
        let end = range.upperBound.line
        return " class=\"md-block\" data-line-start=\"\(start)\" data-line-end=\"\(end)\""
    }

}
