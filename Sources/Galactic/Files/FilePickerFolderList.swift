import Foundation

/// The folders a partly-typed path is choosing between.
///
/// Given `~/pro`, the rows are the children of `~` whose names begin `pro`.
/// Given `~/projects/`, they are all of that directory's children — the
/// trailing separator means the segment is finished and the question has moved
/// on to what is inside.
///
/// The children are **supplied**, not listed here, which is the same division
/// `FilePickerRootInput.completion(for:directories:)` already draws: reading a
/// directory is the presenter's business, and keeping it out of this type is
/// what lets every rule below be tested without a filesystem. It is also what
/// lets the presenter read one directory per parent and filter here on every
/// keystroke after — see `FilePickerPresenter.refreshFolderRows`.
public enum FilePickerFolderList {

    /// Rows offered for a path being typed. More than this cannot be scanned by
    /// eye, and the field is how a reader narrows rather than scrolling.
    public static let rowLimit = 100

    /// - Parameters:
    ///   - query: the root-change query, as typed.
    ///   - children: absolute paths of the candidate parent's child
    ///     directories. Files are the caller's to exclude — a file is not
    ///     somewhere anyone can browse to.
    ///   - limit: how many rows to offer.
    /// - Returns: the folders to show, or none when the query is not a path.
    public static func rows(
        for query: String,
        children: [String],
        limit: Int = rowLimit
    ) -> [FilePickerItem] {
        guard let typed = FilePickerRootInput.expandedPath(query) else {
            return []
        }

        let matching =
            typed.hasSuffix("/")
            ? children
            : children.filter { $0.hasPrefix(typed) }

        return matching
            .sorted(by: precedes)
            .prefix(limit)
            .map { path in
                FilePickerItem(
                    url: URL(fileURLWithPath: path),
                    relativePath: (path as NSString).lastPathComponent,
                    source: .folder
                )
            }
    }

    /// Finder's order — digit runs compared as numbers, and one alphabet rather
    /// than two — spelled out rather than deferred to
    /// `localizedStandardCompare`.
    ///
    /// **Measured**, and the reason this is not the obvious one-liner: the
    /// localized comparator answers `Photo9` before `Photo10` at `en_US` and
    /// `Photo10` before `Photo9` under the locale the test bundle runs in. The
    /// numeric handling drops out silently, so the app and its own tests
    /// disagree about the order and neither reports anything. Naming the two
    /// properties wanted, with `locale: nil`, gives one answer everywhere.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.compare(
            b, options: [.caseInsensitive, .numeric], range: nil, locale: nil
        ) == .orderedAscending
    }
}
