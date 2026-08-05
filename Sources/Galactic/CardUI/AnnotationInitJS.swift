import Foundation

/// The call that hands a reader's annotation state to the page.
///
/// Takes annotation dictionaries rather than a domain type, so an app feeds
/// this from whatever its own store produces through a small adapter of its
/// own. Everything the manager can be configured with travels in this one
/// payload — there is no interpolation into the module itself.
///
/// `artifactContent` is the raw source text behind the rendered document —
/// markdown source, code source, CSV, and so on. When provided, the form's
/// copy-lines affordance slices this string by line or row number to produce
/// the same text the app would persist on submit. Without it the page falls
/// back to scanning the rendered DOM, which is wrong wherever the rendered
/// text differs from the source: markdown tables concatenate cell text with no
/// separators, diff rows carry line-number gutters, and so on.
///
/// `textEntry` is the host's composer key bindings. Passed rather than read
/// from a global here, for the same reason the scrollback renderer takes it as
/// a parameter: this file is shared, and the two apps store their settings in
/// different types. A host that omits it leaves the page on its own defaults.
///
/// `sendBarNoun` opts the document into the send bar and names what it counts
/// — "pending annotation", not "annotation", wherever those are different
/// numbers. Omitting it emits nothing about the bar, so a reader that has no
/// review workflow behind it stays as it was. The count is passed rather than
/// derived from `annotationDicts` because only the app knows which of them a
/// review would actually carry.
public func buildAnnotationInitJS(
    anchorType: String,
    blockSelector: String,
    lineAttr: String,
    endLineAttr: String? = nil,
    refPrefix: String,
    itemLabel: String,
    annotationDicts: [[String: Any]],
    htmlMap: [Int32: String],
    artifactContent: String? = nil,
    referencePath: String? = nil,
    textEntry: [String: [[String: Any]]]? = nil,
    sendBarNoun: String? = nil,
    sendBarCount: Int = 0,
    sendBarComment: Bool = false
) -> String {
    let htmlMapDict: [String: String] = {
        var d: [String: String] = [:]
        for (k, v) in htmlMap {
            d[String(k)] = v
        }
        return d
    }()

    var payload: [String: Any] = [
        "anchorType": anchorType,
        "blockSelector": blockSelector,
        "lineAttr": lineAttr,
        "endLineAttr": endLineAttr as Any,
        "refPrefix": refPrefix,
        "itemLabel": itemLabel,
        "annotations": annotationDicts,
        "htmlMap": htmlMapDict,
    ]
    if let content = artifactContent {
        payload["artifactContent"] = content
    }
    // Only used to build a copy-able reference. Absent for
    // readers with no file behind them, which is how the
    // affordance knows not to offer itself.
    if let referencePath {
        payload["referencePath"] = referencePath
    }
    if let textEntry {
        payload["textEntry"] = textEntry
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: payload
    ),
          let json = String(
              data: data, encoding: .utf8
          )
    else { return "" }

    let initCall = "AnnotationManager.initialize(\(json))"

    guard let sendBarNoun else { return initCall }

    // Single-quoted, so a noun containing one would close the literal early.
    // Nouns are host constants rather than user text, but the escape costs
    // nothing and the failure it prevents is a syntax error in a page that
    // otherwise looks fine until the bar is pressed.
    let escapedNoun = sendBarNoun
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")

    return initCall + """
        ;window.GalaxySendBar.configure({
            noun: '\(escapedNoun)',
            comment: \(sendBarComment),
            invoke: function(comment) {
                AnnotationManager.requestReview(comment);
            }
        });
        window.GalaxySendBar.update(\(sendBarCount));
        """
}
