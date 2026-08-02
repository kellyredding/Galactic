import Foundation

/// How an annotation is fastened to the document it was written against.
///
/// The vocabulary is complete rather than matched to what any one reader
/// renders. A host that shows no diffs still sees `diffRange`, because the
/// alternative — adding a case when a reader arrives — makes every existing
/// `switch` a place the compiler asks about a kind that already existed in
/// somebody's database.
public enum ReaderAnchorType: String, Codable, Sendable {
    case lineRange = "line_range"
    case rowRange = "row_range"
    case blockRange = "block_range"
    case diffRange = "diff_range"
    case whole
}

/// An annotation, as a reader needs to see one.
///
/// Deliberately a protocol over a struct. An annotation is something a host
/// already stores — in a table, behind a CLI, wherever — and the shapes differ:
/// Galaxy's artifacts keep the range inside an anchor payload and record the
/// source text captured when the annotation was written; its snapshots keep the
/// range in dedicated columns and capture nothing. Reading both through one
/// shape lets a reader serve either without one being flattened into the other
/// first, which is how captured text used to get discarded on the way in.
///
/// ### Conforming
///
/// Everything anchor-shaped has a default of nil, so a store that only ever
/// produces line ranges declares the seven common members, `anchorType`, and
/// the two line accessors, and is done. Supply only what the store actually
/// holds — a nil that means "this store does not record that" and a nil that
/// means "this annotation has not got one" are the same nil to a reader, and
/// both are handled.
public protocol ReaderAnnotation {
    var id: Int64 { get }
    var number: Int32 { get }
    var content: String { get }
    var createdAt: String { get }
    var updatedAt: String { get }

    /// Nil until the annotation has been gathered into a review, for hosts
    /// that have such a concept. A host without one leaves both at nil and
    /// the page simply never shows a review badge.
    var reviewNumber: Int32? { get }
    var reviewReviewedAt: String? { get }

    /// Whether the document has changed under the anchor since it was written.
    ///
    /// Readers screen these out; the host decides what stale means. For an
    /// immutable document — a stored snapshot, a captured artifact — nothing
    /// is ever stale and this can answer false forever.
    var isStale: Bool { get }

    var anchorType: ReaderAnchorType { get }

    var anchorStartLine: Int32? { get }
    var anchorEndLine: Int32? { get }
    var anchorLineContent: String? { get }

    var anchorStartRow: Int32? { get }
    var anchorEndRow: Int32? { get }
    var anchorRowContent: String? { get }

    var anchorStartBlock: Int32? { get }
    var anchorEndBlock: Int32? { get }
    var anchorBlockContent: String? { get }

    /// The selected text with no diff markers, for the clipboard and for
    /// suggestion blocks.
    ///
    /// `anchorLineContent` prefixes diff rows with `+ `, `- `, or two spaces so
    /// a reviewing agent can tell additions from deletions from context. That
    /// is the wrong text to paste back into a file. Both forms are recorded
    /// rather than one derived from the other, because stripping a prefix
    /// would corrupt any line whose own code begins with those characters.
    var anchorSourceContent: String? { get }

    /// Per-file position, for an anchor inside a multi-file document.
    ///
    /// A diff reader numbers its rows globally so the page can resolve them
    /// the usual way, and separately records which file a row belonged to and
    /// where in that file it sat. Without this the page can only offer a
    /// global row number, which means nothing to a reader looking at a file.
    var anchorFilePath: String? { get }
    var anchorFileStartLine: Int32? { get }
    var anchorFileEndLine: Int32? { get }
    /// `"new"` when the range lands on added, context, or modified rows;
    /// `"old"` when it is entirely on deleted rows.
    var anchorFileLineSide: String? { get }

    /// Path of the document a whole-document anchor was written against.
    var anchorDocumentPath: String? { get }
}

public extension ReaderAnnotation {
    var reviewNumber: Int32? { nil }
    var reviewReviewedAt: String? { nil }
    var isStale: Bool { false }

    var anchorStartLine: Int32? { nil }
    var anchorEndLine: Int32? { nil }
    var anchorLineContent: String? { nil }

    var anchorStartRow: Int32? { nil }
    var anchorEndRow: Int32? { nil }
    var anchorRowContent: String? { nil }

    var anchorStartBlock: Int32? { nil }
    var anchorEndBlock: Int32? { nil }
    var anchorBlockContent: String? { nil }

    var anchorSourceContent: String? { nil }

    var anchorFilePath: String? { nil }
    var anchorFileStartLine: Int32? { nil }
    var anchorFileEndLine: Int32? { nil }
    var anchorFileLineSide: String? { nil }

    var anchorDocumentPath: String? { nil }
}

/// Flatten one annotation into the shape the page reads.
///
/// The single answer to that question. It used to be answered twice — once
/// when a reader loads and once when its cards are rebuilt — and the two
/// drifted every time one learned something the other did not: card bodies,
/// captured source text, and the per-file reference a diff annotation carries,
/// each missing from the rebuilt form until someone noticed a card that had
/// gone quiet.
///
/// Only the keys belonging to the annotation's own anchor type are emitted.
/// A page reads what it was told to look for and ignores the rest, so writing
/// every key would work — but it would also make a wrong `anchorType` invisible
/// here and puzzling three layers away, inside the manager, at position-sync
/// time.
public func readerAnnotationDict(
    _ a: any ReaderAnnotation
) -> [String: Any] {
    var dict: [String: Any] = [
        "id": a.id,
        "number": a.number,
        "content": a.content,
        "created_at": a.createdAt,
        "updated_at": a.updatedAt,
    ]

    switch a.anchorType {
    case .lineRange:
        dict.putIfPresent("start_line", a.anchorStartLine)
        dict.putIfPresent("end_line", a.anchorEndLine)
        dict.putIfPresent("line_content", a.anchorLineContent)
    case .diffRange:
        // The global data-line values stay — DOM anchoring still uses them —
        // alongside the per-file reference, so the page can show a friendlier
        // label and match cards by path.
        dict.putIfPresent("start_line", a.anchorStartLine)
        dict.putIfPresent("end_line", a.anchorEndLine)
        dict.putIfPresent("line_content", a.anchorLineContent)
        dict.putIfPresent("source_content", a.anchorSourceContent)
        dict.putIfPresent("file_path", a.anchorFilePath)
        dict.putIfPresent("file_start_line", a.anchorFileStartLine)
        dict.putIfPresent("file_end_line", a.anchorFileEndLine)
        dict.putIfPresent("file_line_side", a.anchorFileLineSide)
    case .rowRange:
        dict.putIfPresent("start_row", a.anchorStartRow)
        dict.putIfPresent("end_row", a.anchorEndRow)
        dict.putIfPresent("row_content", a.anchorRowContent)
    case .blockRange:
        dict.putIfPresent("start_block", a.anchorStartBlock)
        dict.putIfPresent("end_block", a.anchorEndBlock)
        dict.putIfPresent("block_content", a.anchorBlockContent)
    case .whole:
        break
    }

    dict.putIfPresent("review_number", a.reviewNumber)
    dict.putIfPresent("review_reviewed_at", a.reviewReviewedAt)
    return dict
}

private extension Dictionary where Key == String, Value == Any {
    /// Absent and null are different to the page: it reads a missing key as
    /// "this anchor does not have one" and falls back, where an explicit null
    /// would be carried into a comparison and lose it.
    mutating func putIfPresent(_ key: String, _ value: (some Any)?) {
        guard let value else { return }
        self[key] = value
    }
}
