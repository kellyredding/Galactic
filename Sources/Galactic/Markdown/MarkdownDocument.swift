import Foundation
import Markdown

/// The one place markdown is parsed.
///
/// Two surfaces need markdown rendered and they need it in different forms: a
/// reader wants HTML for a WebView, a tooltip or an item body wants styled text
/// for a text view. The obvious arrangement is one pipeline each, and that is
/// what both apps had — Galaxy parsing with this library and emitting HTML,
/// Assist Ant parsing with Foundation's own markdown support and emitting an
/// attributed string.
///
/// Two parsers disagree. Not everywhere, and not obviously: on nested lists, on
/// whether a task item is a list item or a paragraph, on what a fenced block's
/// info string means. The same document then reads differently depending on
/// which surface is showing it, and nothing about that is visible until someone
/// puts the two side by side.
///
/// So the parse happens once, here, and the emitters differ. Adding a third
/// surface means adding a visitor, not a pipeline.
public enum MarkdownDocument {
    /// Parse markdown source into a document tree.
    public static func parse(_ source: String) -> Document {
        Document(parsing: source)
    }
}
