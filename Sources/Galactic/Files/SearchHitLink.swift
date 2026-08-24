import Foundation

/// The href a results page puts on a path or a line number.
///
/// A custom scheme rather than a message on the annotation channel, and the
/// reasoning is worth keeping: activating a link *is* a navigation,
/// `decidePolicyFor` is the delegate method that answers navigations, and it
/// already receives this event and discards it. The alternative would have put
/// a third non-annotation case into `AnnotationMessage` — which already carries
/// one it apologises for in its own doc — and forced an edit in every exhaustive
/// switch over that enum, in both applications.
///
/// The path travels as a **query item**, not as the URL's path, so
/// `URLComponents` does the percent-encoding. Real paths contain `#`, `%`, `?`,
/// spaces and characters outside ASCII, and hand-rolled escaping is the failure
/// this avoids by not attempting it.
public enum SearchHitLink {

    public static let scheme = "galactic-open"

    private static let pathKey = "path"
    private static let lineKey = "line"

    /// Build the href. Nil only for an empty path, which is not a file.
    public static func url(path: String, line: Int? = nil) -> URL? {
        guard !path.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        // An empty host with a path-less URL keeps the whole payload in the
        // query, which is the only part with an encoder that handles arbitrary
        // bytes.
        components.host = ""
        var items = [URLQueryItem(name: pathKey, value: path)]
        if let line, line > 0 {
            items.append(URLQueryItem(name: lineKey, value: String(line)))
        }
        components.queryItems = items
        return components.url
    }

    /// Read one back.
    ///
    /// Nil for a wrong scheme or a missing path. A line that is absent,
    /// unparseable, or not positive comes back as nil rather than failing the
    /// whole link — the same rule `LineJumpPresenter.line(from:)` follows, where
    /// nil means "open the file and do nothing else" rather than "complain".
    public static func parse(_ url: URL) -> (path: String, line: Int?)? {
        guard url.scheme == scheme else { return nil }
        guard
            let components = URLComponents(
                url: url, resolvingAgainstBaseURL: false
            )
        else { return nil }
        let items = components.queryItems ?? []
        guard
            let path = items.first(where: { $0.name == pathKey })?.value,
            !path.isEmpty
        else { return nil }

        let line = items.first(where: { $0.name == lineKey })?.value
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        return (path, line)
    }
}
