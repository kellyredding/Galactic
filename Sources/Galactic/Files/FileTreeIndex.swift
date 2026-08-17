import Foundation

/// The files under a root, filtered to what a reader plausibly wants.
///
/// A filtered walk rather than a question put to git, deliberately. `git
/// ls-files` is accurate about what a repository *tracks* and wrong about what
/// a reader wants to *open*: a gitignored `.env` is exactly the file someone
/// opens to check a value, and a committed build directory is exactly the one
/// nobody wants ranked against their own source. The question that matters is
/// "is this noise", which is a different question — and a skip list answers it
/// the same way in a directory that is not a repository at all.
///
/// The list is therefore the entire policy, and it is static for now. Letting
/// each app extend it is a later effort; until then it is one declared value in
/// one file, so changing it is an edit rather than a redesign.
public struct FileTreeIndex: Equatable {

    /// One indexed file: its URL, and its path pre-lowercased for matching.
    ///
    /// Lowercased once here rather than per keystroke. `FuzzyMatch` says
    /// outright that a large corpus wants preparation instead of repeated work,
    /// and a repository is a large corpus — this is the half of that preparation
    /// which belongs to whoever owns the files.
    public struct Item: Equatable {
        public let url: URL
        public let path: String
        public let lowercasedPath: String
        /// Path relative to the index's root, which is what a picker shows.
        public let relativePath: String

        init(url: URL, root: URL) {
            self.url = url
            path = url.path
            lowercasedPath = url.path.lowercased()
            relativePath = FileTabLabel.relativeOrAbbreviated(url, root: root)
        }
    }

    /// The root as walked, with symlinks resolved. Not necessarily the URL the
    /// caller passed — a host that wants relative paths to line up should use
    /// this one rather than its own copy.
    public let root: URL
    public let items: [Item]
    /// True when the walk stopped at its ceiling rather than at the end of the
    /// tree. Reported rather than swallowed: a picker that silently searched
    /// half a repository would rank confidently over the wrong corpus.
    public let wasTruncated: Bool

    /// Directory names never descended into.
    ///
    /// Chosen to be the noise every project has, and no more than that.
    /// Deliberately absent: `lib`, `src`, `bin` and `vendor`. `lib` is
    /// dependencies in Crystal and source in Ruby; `vendor` is checked-in
    /// source often enough to matter. Hiding a reader's own code is a worse
    /// failure than showing them a build directory, so where a name is
    /// genuinely ambiguous it stays in.
    public static let defaultSkipList: Set<String> = [
        // Version control
        ".git", ".hg", ".svn",
        // Node
        "node_modules", "bower_components", ".next", ".nuxt", "dist",
        // Swift and Xcode
        ".build", "build", "DerivedData", ".swiftpm", "Pods",
        // Ruby
        ".bundle", "tmp", "log",
        // Python
        "__pycache__", ".venv", "venv", ".tox", ".mypy_cache",
        ".pytest_cache", ".ruff_cache",
        // Rust, and other build output
        "target", ".gradle", ".terraform", ".dart_tool",
        // Caches and tooling
        ".cache", ".parcel-cache", ".turbo", "coverage", ".idea",
    ]

    /// Walk a root and index what is under it.
    ///
    /// - Parameters:
    ///   - depthCap: how deep to descend. A guard against a pathological tree
    ///     rather than a policy — twelve is past anything a person navigates.
    ///   - resultCap: how many files to index before stopping, reported through
    ///     `wasTruncated`.
    public static func build(
        root: URL,
        skipping skipList: Set<String> = defaultSkipList,
        depthCap: Int = 12,
        resultCap: Int = 50_000
    ) -> FileTreeIndex {
        // Resolved before anything is walked, and `root` here is the resolved
        // one from this point on.
        //
        // The enumerator hands back resolved URLs regardless of what it was
        // given, and on this platform the paths people actually browse are
        // full of symlinks — `/tmp` and `/var` are two, and a home directory
        // often adds more. Comparing an unresolved root against a resolved
        // child fails the prefix test, so every path in the index came back
        // absolute and a picker would have shown a column of them.
        let root = URL(fileURLWithPath: FilePaths.canonical(root))
        let manager = FileManager.default
        // Hidden files are *not* skipped. Dotfiles are among the things most
        // worth opening — `.gitignore`, `.env`, a shell profile — and the kind
        // table was widened during pre-work specifically so they resolve. The
        // hidden directories that are genuinely noise are named in the skip
        // list, which is a more honest instrument than a blanket flag.
        guard
            let walker = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return FileTreeIndex(root: root, items: [], wasTruncated: false)
        }

        var items: [Item] = []
        var truncated = false
        let rootDepth = root.pathComponents.count

        for case let url as URL in walker {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false

            if isDirectory {
                // Skipping the descent rather than filtering afterwards is what
                // makes the list cheap: `node_modules` is never read at all,
                // rather than read and discarded.
                if skipList.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if url.pathComponents.count - rootDepth >= depthCap {
                    walker.skipDescendants()
                }
                continue
            }

            items.append(Item(url: url, root: root))
            if items.count >= resultCap {
                truncated = true
                break
            }
        }

        return FileTreeIndex(root: root, items: items, wasTruncated: truncated)
    }
}
