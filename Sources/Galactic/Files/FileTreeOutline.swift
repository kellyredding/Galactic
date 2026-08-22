import Foundation

/// The rows a file tree is showing, flattened into display order.
///
/// ### Children are supplied, not read
///
/// The same division `FilePickerFolderList` draws, for the same reason: reading
/// a directory is the presenter's business, and keeping it out of here is what
/// lets the ordering, the indentation, the expansion and the filter rules all
/// be tested without a filesystem. It is also what makes the tree lazy by
/// construction — the provider is asked only about directories that are open,
/// so a closed folder costs nothing at all.
///
/// ### Not a tree
///
/// No nodes, no parent pointers, nothing retained between calls but a set of
/// expanded paths. The structure this resembles did exist and was deleted: it
/// held two strings and a URL per file, 56 MB of allocator overhead for 38 MB
/// of path text, and the commit that removed it took the picker from 443–827 ms
/// a keystroke to 4–8. Rebuilding it here would undo that.
///
/// ### Two sources, never mixed
///
/// Browsing is answered from **disk**, one directory per expansion, because the
/// index deliberately skips names a browser must still show — `node_modules`,
/// `.git`, `build`. Filtering is answered from the **index**, because it has to
/// reach the whole tree at once and walking the disk to do that is the
/// thirty-eight-second walk the index exists to avoid.
///
/// They never have to agree, because they are never both answering: an
/// unfiltered tree is built by expansion, a filtered one from the matches. So
/// there is no union, no dedupe, and no question about which source won.
public struct FileTreeOutline {

    /// One directory entry, as the provider reports it.
    public struct Entry: Equatable {
        public let path: String
        public let isDirectory: Bool

        public init(path: String, isDirectory: Bool) {
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    /// A matching file, and where in its path the query landed.
    ///
    /// The offsets are into the path **relative to the root**, which is what the
    /// matcher answers in and what the tree has to take apart: a match spans
    /// folders, so the tree's job is to give each row the part of it that fell
    /// inside that row's own name.
    public struct Match: Equatable {
        public let path: String
        public let highlighted: [Int]

        public init(path: String, highlighted: [Int] = []) {
            self.path = path
            self.highlighted = highlighted
        }
    }

    public struct Row: Equatable, Identifiable {
        public let path: String
        public let depth: Int
        public let isDirectory: Bool
        public let isExpanded: Bool
        /// Offsets into this row's own `name` that the query matched.
        ///
        /// Name-relative, not path-relative, because a row draws a name. A
        /// folder carries whichever part of the query landed on it, so the
        /// highlight runs across the tree the way it runs across a path in the
        /// ranked list.
        public let matchedOffsets: [Int]
        /// True when this directory is on screen only because something under
        /// it matched the filter.
        ///
        /// Collapsing one would hide the match that put it there, so the view
        /// treats the left arrow as "go to parent" on these rather than as
        /// "close". Without the flag that rule has nothing to read.
        public let isRevealedByFilter: Bool

        public var id: String { path }

        /// What the row is labelled with. The last component, so the tree reads
        /// as names at depths rather than as paths repeated at every level.
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// What the reader has opened, by absolute path.
    ///
    /// **Kept apart from what a filter opened**, which is the reason this is a
    /// property rather than a parameter. A filter has to open folders to show
    /// what matched; if it wrote them here, clearing it would either strand
    /// them open or, in closing its own, close the reader's along with them.
    /// Because the filter never touches this set, clearing a filter restores
    /// the reader's tree by construction rather than by remembering to.
    public var expandedByReader: Set<String>

    public init(expandedByReader: Set<String> = []) {
        self.expandedByReader = expandedByReader
    }

    public func isExpanded(_ path: String) -> Bool {
        expandedByReader.contains(path)
    }

    public mutating func toggle(_ path: String) {
        if expandedByReader.contains(path) {
            expandedByReader.remove(path)
        } else {
            expandedByReader.insert(path)
        }
    }

    public mutating func expand(_ path: String) {
        expandedByReader.insert(path)
    }

    public mutating func collapse(_ path: String) {
        expandedByReader.remove(path)
    }

    // MARK: - Browsing

    /// Rows for browsing: what is expanded decides what is visible.
    ///
    /// - Parameter children: a directory's entries. Called only for directories
    ///   that are open, which is the whole of the laziness.
    public func rows(
        root: String, children: (String) -> [Entry]
    ) -> [Row] {
        var result: [Row] = []
        append(
            path: root, depth: 0, isDirectory: true, revealed: false,
            into: &result, children: children
        )
        return result
    }

    private func append(
        path: String,
        depth: Int,
        isDirectory: Bool,
        revealed: Bool,
        into result: inout [Row],
        children: (String) -> [Entry]
    ) {
        let open = isDirectory && expandedByReader.contains(path)
        result.append(
            Row(
                path: path, depth: depth, isDirectory: isDirectory,
                isExpanded: open, matchedOffsets: [],
                isRevealedByFilter: revealed
            )
        )
        guard open else { return }
        for entry in children(path).sorted(by: Self.precedes) {
            append(
                path: entry.path, depth: depth + 1,
                isDirectory: entry.isDirectory, revealed: false,
                into: &result, children: children
            )
        }
    }

    // MARK: - Filtering

    /// Rows for a filter: every match, plus the ancestors needed to reach it,
    /// all open.
    ///
    /// Built from the matched paths rather than by walking and testing each
    /// directory, because the matcher has already decided which paths survive —
    /// asking again per directory would answer the same question a second way,
    /// and the two ways would eventually disagree.
    ///
    /// - Parameter matches: matching **files**, with the query's offsets into
    ///   each one's root-relative path.
    public func rows(root: String, matching matches: [Match]) -> [Row] {
        var childrenOf: [String: Set<String>] = [:]
        var directories: Set<String> = [root]
        var offsets: [String: Set<Int>] = [:]

        for match in matches where match.path.hasPrefix(root + "/") {
            distribute(match, root: root, into: &offsets)

            var current = match.path
            while current != root {
                let parent = (current as NSString).deletingLastPathComponent
                childrenOf[parent, default: []].insert(current)
                if parent != match.path { directories.insert(parent) }
                // A path that does not actually climb to the root would loop
                // here rather than terminate. `hasPrefix` above makes that
                // impossible; the guard makes it impossible to reintroduce.
                guard parent.count < current.count else { break }
                current = parent
            }
        }

        var result: [Row] = []
        appendFiltered(
            path: root, depth: 0, into: &result,
            childrenOf: childrenOf, directories: directories,
            offsets: offsets
        )
        return result
    }

    /// Cut one match's offsets up by path segment.
    ///
    /// The matcher answers in offsets along a whole relative path; a tree draws
    /// that path as one name per row. So each offset is charged to the segment
    /// it fell inside and rewritten as an offset into that segment — otherwise
    /// every row would highlight from the front, which is the wrong letters
    /// everywhere but the first.
    ///
    /// Unioned rather than first-wins, because one folder is an ancestor of many
    /// matches and each of them may have landed somewhere different in its name.
    private func distribute(
        _ match: Match, root: String, into offsets: inout [String: Set<Int>]
    ) {
        guard !match.highlighted.isEmpty else { return }
        let relative = String(match.path.dropFirst(root.count + 1))
        let wanted = Set(match.highlighted)

        var start = 0
        var built = root
        for segment in relative.split(separator: "/", omittingEmptySubsequences: false) {
            let length = segment.count
            built += "/" + segment
            for offset in wanted where offset >= start && offset < start + length {
                offsets[built, default: []].insert(offset - start)
            }
            // One for the separator that follows this segment.
            start += length + 1
        }
    }

    private func appendFiltered(
        path: String,
        depth: Int,
        into result: inout [Row],
        childrenOf: [String: Set<String>],
        directories: Set<String>,
        offsets: [String: Set<Int>]
    ) {
        let isDirectory = directories.contains(path)
        result.append(
            Row(
                path: path, depth: depth, isDirectory: isDirectory,
                isExpanded: isDirectory,
                matchedOffsets: (offsets[path] ?? []).sorted(),
                // The root is where the reader already is, not something the
                // filter revealed.
                isRevealedByFilter: isDirectory && depth > 0
            )
        )
        guard isDirectory, let children = childrenOf[path] else { return }
        let ordered = children
            .map { Entry(path: $0, isDirectory: directories.contains($0)) }
            .sorted(by: Self.precedes)
        for entry in ordered {
            appendFiltered(
                path: entry.path, depth: depth + 1, into: &result,
                childrenOf: childrenOf, directories: directories,
                offsets: offsets
            )
        }
    }

    // MARK: - Order

    /// Finder's order, with folders first.
    ///
    /// Two rules, and the grouping is the one worth naming: Finder itself
    /// interleaves directories with files, and a browser reads better when they
    /// are grouped — which is what every file tree worth copying does. Within
    /// each group the comparison is `FilePickerFolderList.precedes`, so this and
    /// the root-change list cannot disagree about where a name sits.
    public static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return FilePickerFolderList.precedes(
            (a.path as NSString).lastPathComponent,
            (b.path as NSString).lastPathComponent
        )
    }
}
