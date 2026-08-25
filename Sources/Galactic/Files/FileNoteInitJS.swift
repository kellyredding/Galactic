import Foundation

/// Hand a reader's file notes to the page.
///
/// The whole of what an application answers here is `textEntry` — its composer
/// key bindings, which each app keeps in a settings type of its own. Everything
/// else about a file note is the same in every host, and used to be spelled out
/// once per host until a second one arrived to prove it.
///
/// **The anchoring is not a parameter.** Every note is a line range, so a file
/// note anchors the way source anchors and there is no second answer a caller
/// could give. Passing it in would only create a way to be wrong.
///
/// **The send bar says "note", not "pending note".** An artifact reader has to
/// distinguish the two because a document there can show twelve cards of which
/// nine belong to a review that already happened. A file note has no such
/// afterlife — sending is what destroys it, so every note on screen is unsent by
/// definition and the plain word is the accurate one.
public func buildFileNoteInitJS(
    itemLabel: String,
    notes: [FileNote],
    fileContent: String,
    referencePath: String?,
    textEntry: [String: [[String: Any]]]?,
    restoringFormState: String?,
    sendBarCount: Int
) -> String {
    buildAnnotationInitJS(
        anchoring: SourceRenderer.anchoring,
        itemLabel: itemLabel,
        annotations: notes,
        htmlMap: fileNoteHTMLMap(notes),
        // The frozen source, so the form's copy-lines affordance slices the
        // same text a review will quote rather than scraping it out of the DOM.
        artifactContent: fileContent,
        referencePath: referencePath,
        textEntry: textEntry,
        restoringFormState: restoringFormState,
        sendBarNoun: "note",
        sendBarCount: sendBarCount,
        // The review's own summary, which leads the message the way it leads a
        // code review. Set-wide, so `FileSet` owns it rather than any one file.
        sendBarComment: true
    )
}

/// Card bodies, keyed the way the page keys them.
///
/// Not rendered markdown, despite the name the engine's helper carries: a note
/// is displayed verbatim, so the only transformation is escaping the three
/// characters that would otherwise end the surrounding element early.
public func fileNoteHTMLMap(_ notes: [FileNote]) -> [Int32: String] {
    var map: [Int32: String] = [:]
    for note in notes {
        map[note.number] = escapeAnnotationContent(note.content)
    }
    return map
}

/// One note, in the shape the page's `annotationCreated` / `annotationUpdated`
/// echo expects: the annotation itself plus its rendered body.
///
/// The page keeps a card latched in its submitting state until one of those two
/// arrives, so an echo is not a courtesy — a create that writes to the store and
/// forgets to reply leaves the form permanently stuck with no way back.
public func fileNoteEchoPayload(_ note: FileNote) -> String {
    let payload: [String: Any] = [
        "annotation": readerAnnotationDict(note),
        "renderedHTML": escapeAnnotationContent(note.content),
    ]
    guard
        let data = try? JSONSerialization.data(withJSONObject: payload),
        let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
}
