import Foundation

/// Reads a source theme pair from a directory a host names.
///
/// Galactic never learns a path. The host owns where its themes live and hands
/// over a URL, the same way appearance is passed rather than read from a
/// global — which is also what lets the two apps point at different
/// directories and carry different themes.
///
/// The pair is two files, `theme-dark.css` and `theme-light.css`, named rather
/// than discovered so that finding the active theme needs no setting. Either
/// may be absent: a host with only a dark theme keeps the stock light one.
public struct SourceThemeLoader {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The theme for an appearance, or nil to leave it stock.
    ///
    /// Nil covers every way this can fail — no file, an unreadable file, a
    /// declined one — because the caller's response is the same in each case
    /// and the difference is already in the log.
    public func theme(isDark: Bool) -> SourceTheme? {
        Self.cache.theme(
            at: directory.appendingPathComponent(
                isDark ? "theme-dark.css" : "theme-light.css"
            )
        )
    }

    /// Resolved per document build, so an edited stylesheet appears on the next
    /// reader without restarting the app. The cache is what keeps that from
    /// meaning a read and a parse per render: a file whose modification date
    /// and size are unchanged answers from memory.
    private static let cache = Cache()

    private final class Cache {
        private struct Entry {
            let modified: Date
            let size: Int
            let theme: SourceTheme?
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func theme(at url: URL) -> SourceTheme? {
            let path = url.path
            guard
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: path),
                let modified = attributes[.modificationDate] as? Date,
                let size = attributes[.size] as? Int
            else {
                // No file is the ordinary case, not a fault: most installs
                // never have one. Forget any theme this path used to hold so
                // deleting a stylesheet returns the reader to stock.
                lock.withLock { entries[path] = nil }
                return nil
            }

            let cached = lock.withLock { entries[path] }
            if let cached, cached.modified == modified, cached.size == size {
                return cached.theme
            }

            let theme = read(url)
            lock.withLock {
                entries[path] = Entry(
                    modified: modified, size: size, theme: theme
                )
            }
            return theme
        }

        private func read(_ url: URL) -> SourceTheme? {
            guard
                let css = try? String(contentsOf: url, encoding: .utf8)
            else {
                GalacticLog.debug(
                    "source-theme",
                    "\(url.lastPathComponent) could not be read as UTF-8"
                )
                return nil
            }
            switch SourceThemeStylesheet.theme(from: css) {
            case .success(let theme):
                return theme
            case .failure(let rejection):
                // Named and explained rather than absorbed: a stylesheet that
                // silently does nothing reads as a bug in the reader.
                GalacticLog.debug(
                    "source-theme",
                    "\(url.lastPathComponent) declined — \(rejection.reason)"
                )
                return nil
            }
        }
    }
}
