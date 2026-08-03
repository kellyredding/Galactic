import Foundation

/// Font stacks a reader document is set in.
public enum ReaderFont {
    public static let mono = "ui-monospace, 'SF Mono', Monaco, "
        + "'Cascadia Code', 'Roboto Mono', Menlo, monospace"
    public static let sans = "-apple-system, BlinkMacSystemFont, "
        + "'SF Pro Text', 'Helvetica Neue', sans-serif"
}

/// Assemble the page a reader is rendered into.
///
/// Seven readers each built their own document and the frames were the same
/// one: doctype, charset, viewport, title, a `:root` block, a reset, `html,
/// body` set to the theme's colours, the reader's own rules, the annotation
/// stylesheet, the body, and a run of script tags in a fixed order. What
/// differed between them was the body, the rules, and the font — three things
/// out of eleven.
///
/// ### The script tail
///
/// The card scripts go in a fixed order and always have. What surrounds them
/// does not, which is why the two hooks exist rather than one list: a reader
/// that highlights has to load the library and then invoke it, and *when* it
/// invokes differs — one highlights every element on load, one walks its own
/// rows and skips those already marked up. Attempting to serve both from a
/// single ordered list is how the surrounding scripts ended up copied into
/// each reader in the first place.
///
/// `scriptsBeforeCards` runs after the body exists and before the annotation
/// machinery is installed; `scriptsAfterCards` runs last. Anything that
/// rewrites the DOM the cards anchor to belongs in the first.
///
/// ### Assets
///
/// Nothing is included by default. The diagram bundle in particular is over
/// three megabytes and it is inlined into the document rather than linked, so
/// a reader that includes it unconditionally pays that on every render and on
/// every theme change. Ask a `FileKind` what the page actually needs.
public enum ReaderDocument {

    /// Which card scripts a document installs.
    public enum CardScripts: Equatable {
        /// The full set. What a reader with anchorable regions wants.
        case full
        /// Everything except the add-note affordance, for a document with
        /// nothing to point inside of — an image, a diagram. The composer
        /// still works; there is simply nowhere to start one from.
        case withoutAddNote
        /// No annotation machinery at all.
        case none
    }

    public static func render(
        theme: ReaderTheme,
        title: String = "Reader",
        fontFamily: String = ReaderFont.sans,
        fontSize: String = "13px",
        lineHeight: String = "1.45",
        css: String = "",
        body: String,
        scriptsBeforeCards: String = "",
        scriptsAfterCards: String = "",
        cardScripts: CardScripts = .full
    ) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport"
              content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
            background: \(theme.background);
            color: \(theme.foreground);
            font-family: \(fontFamily);
            font-size: \(fontSize);
            line-height: \(lineHeight);
            -webkit-font-smoothing: antialiased;
        }
        \(css)
        </style>
        \(annotationStyleTag(theme: theme))
        </head>
        <body>
        \(body)
        \(scriptTag(scriptsBeforeCards))
        \(cardScriptTags(cardScripts))
        \(scriptTag(scriptsAfterCards))
        </body>
        </html>
        """
    }

    /// Everything the annotation layer needs to look like itself, as one
    /// complete `<style>` element.
    ///
    /// The two halves travel together on purpose. The rules read a dozen
    /// custom properties, and the properties are useless without the rules,
    /// so a caller that takes one and forgets the other gets a page where
    /// annotations *work* and are simply invisible — the cards land in the
    /// right place, carry the right text, and render as unstyled white boxes.
    /// Nothing errors and nothing logs.
    ///
    /// That is not hypothetical. Splitting them across two call sites is
    /// exactly how it happened once already, in the reader that splices this
    /// into a document arriving with its own markup — the counterpart case to
    /// `cardScriptTags`, and the reason both exist as callable pieces rather
    /// than only as parts of `render`.
    public static func annotationStyleTag(theme: ReaderTheme) -> String {
        """
        <style>
        :root {
            \(annotationCSSVars(isDark: theme.isDark))
        }
        \(annotationCSS)
        </style>
        """
    }

    /// The card scripts, in the order they have to load.
    ///
    /// Order is not arbitrary and is not the alphabet: the manager expects
    /// the text helpers, the clipboard, and the composer bindings to already
    /// be installed when it initialises, and the emoji data has to precede
    /// the autocomplete that searches it.
    ///
    /// Public because a reader sometimes cannot use `render` — a document
    /// that already has its own `<html>` gets the annotation machinery
    /// spliced into it rather than being rebuilt around. Such a reader still
    /// needs this exact run in this exact order, and reproducing it by hand
    /// is how a document ends up with a manager that initialises before the
    /// helpers it calls.
    public static func cardScriptTags(_ scripts: CardScripts) -> String {
        guard scripts != .none else { return "" }
        var parts = [
            cardTextJS, clipboardCopyJS, textEntryJS, suggestionInsertJS,
        ]
        if scripts == .full { parts.append(addNoteButtonJS) }
        parts.append(contentsOf: [
            annotationManagerJS, EmojiJS.data, EmojiJS.autocomplete,
        ])
        return parts.map { "<script>\($0)</script>" }
            .joined(separator: "\n")
    }

    /// Empty in, empty out — an empty `<script>` is harmless but it is also
    /// noise in a document someone may well be reading in a web inspector.
    private static func scriptTag(_ source: String) -> String {
        source.isEmpty ? "" : "<script>\(source)</script>"
    }
}
