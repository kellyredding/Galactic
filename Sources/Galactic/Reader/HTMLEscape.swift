import Foundation

/// HTML-escaping for text spliced into a reader document.
///
/// Escapes the full five: `&`, `<`, `>`, `"`, and `'`. Three narrower sets
/// were in use before this existed — `&<>`, `&<>"`, and `&<>"'` — one per
/// reader, chosen by whoever wrote that reader rather than by what its content
/// could contain. The narrow ones were not wrong where they stood, which is
/// what let them survive: a bare apostrophe in a text node renders as an
/// apostrophe. They were wrong as a *rule*, because one helper name meant
/// three different things, and moving a call from one reader to another
/// silently changed what it did.
///
/// Over-escaping is invisible. A browser renders `&#39;` and `'` identically
/// in a text node, and both are safe inside an attribute value.
/// Under-escaping is a defect. The widest set is therefore the only one
/// correct in every position, and costs nothing in the positions where a
/// narrower one would also have worked.
///
/// ### The JavaScript twin
///
/// A reader that re-renders rows in the page after load — Galaxy's diff reader
/// expanding a collapsed gap — needs the same escape in JavaScript. That copy
/// is served from `javaScriptFunction` below rather than written out again at
/// the call site, because the two must agree exactly: rows revealed by
/// expansion sit in the DOM beside rows rendered here, and if the two escapes
/// differ the seam shows only in content that happens to contain a quote.
/// Both halves would be individually correct, no test would fail, and the
/// mismatch would be visible to a reader looking at one file and invisible to
/// everyone else. Having one definition removes the category.
public enum HTMLEscape {
    /// Escape `&`, `<`, `>`, `"`, and `'` for embedding in a document.
    ///
    /// Ampersand is replaced first. Doing it in any other order would
    /// double-escape the entities the other replacements introduce, turning
    /// `<` into `&amp;lt;` and rendering it as literal `&lt;` on the page.
    public static func text(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The same escape as a JavaScript function declaration named
    /// `htmlEscape`, for splicing into a page that renders rows of its own.
    ///
    /// Declared here rather than in the script that needs it so the two
    /// escapes cannot drift — see the note above. A page splices this in and
    /// then calls `htmlEscape(...)` as though it had written it.
    // js-validate
    public static let javaScriptFunction: String = """
    function htmlEscape(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }
    """
}
