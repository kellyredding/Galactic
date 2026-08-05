import Foundation

/// How a reader anchors annotations into its own markup.
///
/// Every reader answers the same five questions — what to call the anchor
/// type, which elements are anchorable, which attributes carry their position,
/// and what to name one in a reference — and every reader used to answer them
/// inline at the call that hands them to the page. Eight argument lists,
/// restated at each of the two places a reader builds its init script.
///
/// ### And what the reader will answer for
///
/// Screening belongs here too, in the same value, because it is the same
/// knowledge. It used to live apart, and the two disagreed: the rebuild path
/// applied one blanket rule to every reader, which excluded whole-document
/// anchors — exactly the annotations a whole-document reader exists to show,
/// and none of the ones it does not. Refreshing a diagram inverted its cards.
///
/// The two are not the same string, which is why keeping them together
/// matters. A diff reader is told `line_range`, because its rows carry the
/// `data-line` attributes the page resolves the usual way, but its annotations
/// are written as `diff_range` so they can also record a per-file reference.
/// Both kinds belong to it, and a rule derived from what the page was told
/// would drop half of them.
public struct ReaderAnchoring {
    /// What the page is told to resolve. Not necessarily what the host stores.
    public let anchorType: String
    /// CSS selector matching every anchorable element.
    public let blockSelector: String
    /// Attribute carrying an element's position.
    public let lineAttr: String
    /// Attribute carrying the end of a multi-line element's span, for markup
    /// where one element covers a range. Nil where each element is one unit.
    public let endLineAttr: String?
    /// What one unit is called in a copied reference — "Line", "Row", "Block".
    public let refPrefix: String

    /// Anchor kinds this reader will place, or nil when it screens nothing.
    private let accepted: Set<ReaderAnchorType>?

    public init(
        anchorType: String,
        blockSelector: String,
        lineAttr: String,
        endLineAttr: String? = nil,
        refPrefix: String,
        accepting: Set<ReaderAnchorType>?
    ) {
        self.anchorType = anchorType
        self.blockSelector = blockSelector
        self.lineAttr = lineAttr
        self.endLineAttr = endLineAttr
        self.refPrefix = refPrefix
        self.accepted = accepting
    }

    public func accepts(_ type: ReaderAnchorType) -> Bool {
        guard let accepted else { return true }
        return accepted.contains(type)
    }

    /// Screen a host's annotations down to the ones this reader can place.
    ///
    /// Stale annotations go too. Both halves in one call, because a reader
    /// that filters one and forgets the other shows a card pinned to text that
    /// has moved — and every reader wanted both every time.
    public func screen(
        _ annotations: [any ReaderAnnotation]
    ) -> [any ReaderAnnotation] {
        annotations.filter { !$0.isStale && accepts($0.anchorType) }
    }

    // MARK: - Common shapes

    /// Markup where each anchorable element is one line.
    public static func lines(
        selector: String,
        lineAttr: String = "data-line",
        endLineAttr: String? = nil,
        accepting: Set<ReaderAnchorType> = [.lineRange]
    ) -> ReaderAnchoring {
        ReaderAnchoring(
            anchorType: ReaderAnchorType.lineRange.rawValue,
            blockSelector: selector,
            lineAttr: lineAttr,
            endLineAttr: endLineAttr,
            refPrefix: "Line",
            accepting: accepting
        )
    }

    /// Tabular markup, anchored by row ordinal.
    public static func rows(
        selector: String = "tr[data-row]",
        lineAttr: String = "data-row"
    ) -> ReaderAnchoring {
        ReaderAnchoring(
            anchorType: ReaderAnchorType.rowRange.rawValue,
            blockSelector: selector,
            lineAttr: lineAttr,
            refPrefix: "Row",
            accepting: [.rowRange]
        )
    }

    /// Prose or structured markup, anchored by block index.
    public static func blocks(
        selector: String,
        lineAttr: String = "data-block-index"
    ) -> ReaderAnchoring {
        ReaderAnchoring(
            anchorType: ReaderAnchorType.blockRange.rawValue,
            blockSelector: selector,
            lineAttr: lineAttr,
            refPrefix: "Block",
            accepting: [.blockRange]
        )
    }

    /// A document with nothing to point inside of — an image, a diagram.
    ///
    /// Screens nothing. An annotation such a reader cannot place is still
    /// worth showing: it counts toward a review either way, and hiding it
    /// would leave pending work with nowhere to appear.
    public static let whole = ReaderAnchoring(
        anchorType: ReaderAnchorType.whole.rawValue,
        blockSelector: "",
        lineAttr: "",
        refPrefix: "",
        accepting: nil
    )
}

/// Hand a reader's annotation state to the page.
///
/// The anchoring-shaped overload of `buildAnnotationInitJS`. Takes the five
/// page-facing values as one declared thing and screens the annotations on the
/// way through, so a caller cannot describe its markup one way and filter for
/// another.
///
/// `restoringFormState` is whatever a previous page was carrying in its
/// composer, as handed over by `ReaderHostView`. Appended to the same script
/// rather than evaluated separately, so the page never exists in a state where
/// annotations have initialised and the rescued text has not yet arrived —
/// a gap the reader would see as their note vanishing and coming back.
public func buildAnnotationInitJS(
    anchoring: ReaderAnchoring,
    itemLabel: String,
    annotations: [any ReaderAnnotation],
    htmlMap: [Int32: String],
    artifactContent: String? = nil,
    referencePath: String? = nil,
    textEntry: [String: [[String: Any]]]? = nil,
    restoringFormState: String? = nil,
    sendBarNoun: String? = nil,
    sendBarCount: Int = 0,
    sendBarComment: Bool = false
) -> String {
    let restore = restoringFormState.map {
        "; AnnotationManager.restoreFormState(\($0))"
    } ?? ""
    return buildAnnotationInitJS(
        anchorType: anchoring.anchorType,
        blockSelector: anchoring.blockSelector,
        lineAttr: anchoring.lineAttr,
        endLineAttr: anchoring.endLineAttr,
        refPrefix: anchoring.refPrefix,
        itemLabel: itemLabel,
        annotationDicts: anchoring.screen(annotations)
            .map(readerAnnotationDict),
        htmlMap: htmlMap,
        artifactContent: artifactContent,
        referencePath: referencePath,
        textEntry: textEntry,
        sendBarNoun: sendBarNoun,
        sendBarCount: sendBarCount,
        sendBarComment: sendBarComment
    ) + restore
}
