import AppKit
import Markdown

/// Markdown as styled text, for a surface that is not a web view.
///
/// The second emitter over `MarkdownDocument`'s parse. A reader shows markdown
/// in a `WKWebView` and gets HTML; an item body or a hover tooltip shows it in
/// an `NSTextView` and gets this. Same parse, so the two cannot disagree about
/// what the document *is* — only about how to draw it.
///
/// ### Why not Foundation's markdown support
///
/// `AttributedString(markdown:)` produces a flat run sequence annotated with
/// `presentationIntent`, and recovering block structure from it means grouping
/// contiguous runs by intent identity and inferring nesting from how many list
/// components a run happens to carry. It works, and it was what one app used —
/// but it is a second parser, and a second parser is a second opinion. Walking
/// the tree the reader already parsed costs about the same and removes the
/// possibility of the two rendering the same document differently.
///
/// It is also simply better informed. A task item is `ListItem.checkbox` here,
/// where the flat form left it as the literal characters `[x] ` at the head of
/// the text — detectable only by prefix-matching, and indistinguishable from a
/// list item that genuinely begins with a bracket.
public enum MarkdownAttributedText {

    /// Render markdown as styled text.
    ///
    /// `bodyFont` sets the scale everything else is derived from — heading
    /// sizes step up from it, code blocks match its size in a monospaced face.
    /// Taken as a parameter because a tooltip and a document body want
    /// different scales from the same markup.
    public static func attributed(
        _ markdown: String,
        bodyFont: NSFont = NSFont.preferredFont(forTextStyle: .body)
    ) -> NSAttributedString {
        var visitor = MarkdownAttributedVisitor(bodyFont: bodyFont)
        let out = visitor.visit(MarkdownDocument.parse(markdown))
        return out.length > 0 ? out : plain(markdown, bodyFont: bodyFont)
    }

    /// Nothing rendered — an empty document, or one made entirely of nodes
    /// this visitor draws as nothing. Showing the source is better than
    /// showing a blank.
    static func plain(_ s: String, bodyFont: NSFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

/// Walks a parsed document and builds styled text.
///
/// Internal for the same reason the HTML emitter is: conforming publicly to
/// `MarkupVisitor` would oblige every visit method to be public. The door is
/// `MarkdownAttributedText.attributed`.
struct MarkdownAttributedVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    let bodyFont: NSFont

    /// How deep inside nested lists the walk currently is. Held rather than
    /// derived, because a list item cannot see its own ancestry.
    private var listDepth = 0

    init(bodyFont: NSFont) {
        self.bodyFont = bodyFont
    }

    // MARK: - Blocks

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        joinChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        joinBlocks(document.children.map { visit($0) })
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        paragraphStyled(joinChildren(of: paragraph), style: blockStyle())
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: joinChildren(of: heading)
        )
        let size = bodyFont.pointSize + headingBump(heading.level)
        text.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: size),
            range: text.whole
        )
        let style = blockStyle()
        style.paragraphSpacingBefore = 10
        style.paragraphSpacing = 4
        return paragraphStyled(text, style: style)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        // Trailing newline dropped: a fenced block's source always carries
        // one, and the join between blocks supplies the separation.
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }

        let style = blockStyle()
        style.firstLineHeadIndent = 16
        style.headIndent = 16
        return NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(
                ofSize: bodyFont.pointSize, weight: .regular
            ),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: joinBlocks(blockQuote.children.map { visit($0) })
        )
        text.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: text.whole
        )
        let style = blockStyle()
        style.firstLineHeadIndent = 16
        style.headIndent = 16
        text.addAttribute(.paragraphStyle, value: style, range: text.whole)
        return text
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        visitList(list, ordered: false)
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        visitList(list, ordered: true)
    }

    private mutating func visitList(
        _ list: any ListItemContainer & Markup,
        ordered: Bool
    ) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }

        let indent = CGFloat(listDepth) * 18
        let tab = indent + 18

        var rendered: [NSAttributedString] = []
        for (offset, item) in list.listItems.enumerated() {
            let style = blockStyle()
            style.paragraphSpacing = 3
            style.firstLineHeadIndent = indent
            style.headIndent = tab
            style.tabStops = [
                NSTextTab(textAlignment: .left, location: tab),
            ]

            let marker = NSAttributedString(
                string: self.marker(for: item, ordered: ordered, at: offset),
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]
            )
            let body = NSMutableAttributedString(attributedString: marker)
            let content = NSMutableAttributedString(
                attributedString: joinBlocks(item.children.map { visit($0) })
            )
            // The item's own paragraph style would otherwise override the
            // indentation this level just established.
            content.addAttribute(
                .paragraphStyle, value: style, range: content.whole
            )
            body.append(content)
            rendered.append(body)
        }
        return joinBlocks(rendered)
    }

    /// A checkbox where the source said so, otherwise a bullet or an ordinal.
    ///
    /// `checkbox` is answered by the parse. The flat-run form this replaced
    /// could only look for the characters `[x] ` at the head of the text,
    /// which cannot tell a task item from an item that starts with a bracket.
    private func marker(
        for item: ListItem, ordered: Bool, at offset: Int
    ) -> String {
        switch item.checkbox {
        case .checked: return "☑\t"
        case .unchecked: return "☐\t"
        case .none: break
        }
        return ordered ? "\(offset + 1).\t" : "•\t"
    }

    mutating func visitThematicBreak(_: ThematicBreak) -> NSAttributedString {
        NSAttributedString(string: "————", attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: blockStyle(),
        ])
    }

    // MARK: - Inlines

    /// Plain text, with any bare URL in it linked.
    ///
    /// The autolink lands here rather than in `MarkdownDocument`, which would
    /// reach the HTML emitter too and so change what a reader shows — a
    /// separate surface, with its own annotation and text-selection behaviour
    /// to answer for. `MarkdownAutolink` is deliberately emitter-agnostic so
    /// that decision stays reversible; the asymmetry is scope, not principle.
    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        let plain = inline(text.string, font: bodyFont)
        // A link's own label is already inside a link, so autolinking it would
        // nest one address in another. Usually invisible here, because
        // `visitLink` overwrites the whole label with the authored
        // destination — but not when there is no authored destination to
        // overwrite it with. `[https://shown.example]()` says explicitly that
        // this text goes nowhere, and without this guard it would go to
        // itself.
        guard !isInsideLink(text) else { return plain }

        let spans = MarkdownAutolink.spans(in: text.string)
        guard !spans.isEmpty else { return plain }

        let out = NSMutableAttributedString(attributedString: plain)
        for span in spans {
            out.addAttribute(
                .link,
                value: span.url,
                range: NSRange(span.range, in: text.string)
            )
        }
        return out
    }

    /// Walked rather than tracked, because emphasis and strong nest in between:
    /// the text of `[**https://example.com**](…)` has a `Strong` for a parent,
    /// not the `Link`.
    private func isInsideLink(_ markup: any Markup) -> Bool {
        var ancestor = markup.parent
        while let node = ancestor {
            if node is Link { return true }
            ancestor = node.parent
        }
        return false
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        restyled(joinChildren(of: strong)) {
            NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask)
        }
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        restyled(joinChildren(of: emphasis)) {
            NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask)
        }
    }

    mutating func visitInlineCode(_ code: InlineCode) -> NSAttributedString {
        inline(
            code.code,
            font: NSFont.monospacedSystemFont(
                ofSize: bodyFont.pointSize, weight: .regular
            )
        )
    }

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: joinChildren(of: link)
        )
        // The URL is attached and left unstyled. A text view styles `.link`
        // runs through `linkTextAttributes`, so colouring here would fight
        // whatever the host has chosen.
        if let destination = link.destination,
           let url = URL(string: destination)
        {
            text.addAttribute(.link, value: url, range: text.whole)
        }
        return text
    }

    mutating func visitSoftBreak(_: SoftBreak) -> NSAttributedString {
        inline(" ", font: bodyFont)
    }

    mutating func visitLineBreak(_: LineBreak) -> NSAttributedString {
        inline("\n", font: bodyFont)
    }

    // MARK: - Assembly

    private mutating func joinChildren(of markup: any Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children { out.append(visit(child)) }
        return out
    }

    /// Join blocks with a newline that carries the preceding block's style, so
    /// `paragraphSpacing` applies to the gap rather than being swallowed.
    private func joinBlocks(_ blocks: [NSAttributedString]) -> NSAttributedString {
        let kept = blocks.filter { $0.length > 0 }
        let out = NSMutableAttributedString()
        for (i, block) in kept.enumerated() {
            out.append(block)
            guard i < kept.count - 1 else { continue }
            var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont]
            if let style = block.attribute(
                .paragraphStyle, at: block.length - 1, effectiveRange: nil
            ) {
                attrs[.paragraphStyle] = style
            }
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    private func inline(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// Re-run every font in a rendered inline span through a transform, so
    /// nesting composes — bold inside italic keeps both.
    private func restyled(
        _ text: NSAttributedString,
        _ transform: (NSFont) -> NSFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: out.whole) { value, range, _ in
            let font = (value as? NSFont) ?? bodyFont
            out.addAttribute(.font, value: transform(font), range: range)
        }
        return out
    }

    private func blockStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        return style
    }

    private func paragraphStyled(
        _ text: NSAttributedString,
        style: NSParagraphStyle
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.paragraphStyle, value: style, range: out.whole)
        return out
    }

    private func headingBump(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 5
        case 3: return 3
        default: return 1
        }
    }
}

private extension NSAttributedString {
    var whole: NSRange { NSRange(location: 0, length: length) }
}
