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
    textEntry: [String: [[String: Any]]]? = nil
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

    return "AnnotationManager.initialize(\(json))"
}
