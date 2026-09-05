import Foundation

/// Where the browser has to be rooted for one file to be reachable in it.
///
/// Its own type because the answer is policy rather than path arithmetic, and
/// the policy has a cliff in it. Climbing until the root contains the file is
/// the lowest common ancestor of the two, and for a file on another volume or
/// under `/tmp` that is `/` — a tree nobody browses, and the one root no
/// existing corpus covers, so it would be walked from cold.
///
/// The home directory is not that case and is a fine answer: it is already an
/// adopted root, and every project beneath it is served by it rather than
/// walked separately.
public enum FileRevealRoot {

    /// - Parameters:
    ///   - floor: the highest the climb may go, inclusive. The home directory
    ///     in both applications; a parameter so the rule can be tested without
    ///     one.
    /// - Returns: the root to browse `file` in. The current root when it
    ///   already contains the file, the common ancestor when climbing reaches
    ///   one at or below `floor`, and the file's own folder when it does not.
    public static func resolve(file: URL, from current: URL, floor: URL) -> URL {
        // Asked through `relativePath` rather than lexically, so a root reached
        // by one spelling and a file opened by another still read as the same
        // tree. The climb below is lexical because that is how the tree
        // descends — see `FileDirectoryReader`.
        if FilePaths.relativePath(of: file, under: current) != nil {
            return current
        }
        let ancestor = commonAncestor(current.path, file.path)
        guard isAtOrUnder(ancestor, floor.path) else {
            return file.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: ancestor)
    }

    /// Compared component-wise rather than by string prefix, so `project-other`
    /// and `project` share `/` rather than seven characters.
    private static func commonAncestor(_ a: String, _ b: String) -> String {
        var shared: [Substring] = []
        for (left, right) in zip(a.split(separator: "/"), b.split(separator: "/"))
        {
            guard left == right else { break }
            shared.append(left)
        }
        return "/" + shared.joined(separator: "/")
    }

    private static func isAtOrUnder(_ path: String, _ floor: String) -> Bool {
        path == floor || FilePaths.relative(path, under: floor) != nil
    }
}
