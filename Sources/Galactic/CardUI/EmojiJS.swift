import Foundation

/// The emoji dataset and its autocomplete behaviour, as shipped JavaScript.
///
/// Both card surfaces offer emoji autocomplete in their composer, and both used
/// to load these two files themselves — Galaxy read them from two places with
/// identical bodies, once privately inside the scrollback renderer and once as
/// globals beside the annotation manager. One accessor now serves every caller.
///
/// Read from the package bundle rather than the app's. A package cannot see
/// `Bundle.main`, and it should not want to: these files ship with the code that
/// depends on them, so a consumer cannot end up with the behaviour and not the
/// data.
///
/// Loaded once and held, because both are large — the dataset alone is several
/// thousand lines — and a document rebuild on every theme or font change would
/// otherwise re-read them from disk.
public enum EmojiJS {
    /// The emoji dataset the autocomplete searches.
    public static let data: String = load("emoji-data")

    /// The autocomplete behaviour itself. Expects `data` to be present.
    public static let autocomplete: String = load("emoji-autocomplete")

    /// Missing or unreadable resolves to empty rather than trapping.
    ///
    /// Emoji autocomplete is a convenience layered onto a composer; losing it
    /// should degrade that composer, not prevent the document from rendering at
    /// all. An empty string injects a harmless empty `<script>`.
    private static func load(_ name: String) -> String {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "js"),
            let content = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return content
    }
}
