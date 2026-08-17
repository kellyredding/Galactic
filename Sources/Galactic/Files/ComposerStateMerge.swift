import Foundation

/// Splitting the page's rescued composer state by what it belongs to.
///
/// `AnnotationManager.getFormState()` returns one object mixing two lifetimes.
/// The card state — which block, which lines, the half-written textarea, which
/// card is expanded — belongs to **the file**. The send bar's overall comment
/// belongs to **the review**, and a review spans every file in the set.
///
/// A single reader is rebuilt on every file switch, so the rescue is the only
/// thing carrying a reader's work across it. Filing the blob whole onto the
/// outgoing tab would make a summary reappear on whichever file happened to be
/// showing when it was typed, and vanish everywhere else — which is worse than
/// losing it, because it looks like the app forgetting selectively.
///
/// Both directions degrade to nil rather than throwing. A rescue that cannot be
/// read should cost the composer and never the file switch.
enum ComposerStateMerge {

    /// Keys the page writes, and the only two this type interprets. Everything
    /// else in the blob is passed through untouched, because what a half-written
    /// card consists of is the page's business.
    private static let commentKey = "overallComment"
    private static let expandedKey = "overallExpanded"

    /// Lift the set-wide half out of a rescued blob.
    ///
    /// Returns nil when there is nothing to lift — unreadable JSON, or a page
    /// that had no comment. A caller keeps whatever the set already held in that
    /// case rather than clearing it: a rebuild that failed to report a comment is
    /// not a reader deleting one.
    static func overallComment(
        from json: String?
    ) -> (text: String, expanded: Bool)? {
        guard let object = dictionary(from: json) else { return nil }
        guard let text = object[commentKey] as? String, !text.isEmpty else {
            return nil
        }
        return (text, object[expandedKey] as? Bool ?? false)
    }

    /// A file's own blob with the set's comment written into it.
    ///
    /// Called on the way *into* a file, so the incoming page is handed that
    /// file's card state and the review's comment together — which is the state
    /// the reader actually left, even though no single page ever held it.
    ///
    /// A nil `perFile` with a comment to restore still produces a blob: the
    /// comment survives arriving at a file that has no card state of its own,
    /// which is the common case after a fresh open.
    static func merged(
        perFile: String?,
        overallComment: String,
        expanded: Bool
    ) -> String? {
        var object = dictionary(from: perFile) ?? [:]

        if overallComment.isEmpty {
            // Removed rather than written as empty. The page tests the field
            // for truthiness, so an empty string would be skipped anyway —
            // but leaving a stale one in from the outgoing file would not be.
            object.removeValue(forKey: commentKey)
            object.removeValue(forKey: expandedKey)
        } else {
            object[commentKey] = overallComment
            object[expandedKey] = expanded
        }

        guard !object.isEmpty else { return nil }
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func dictionary(from json: String?) -> [String: Any]? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }
}
