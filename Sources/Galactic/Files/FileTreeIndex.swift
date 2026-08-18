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

    /// One indexed file: the part of its path below the root, and that path
    /// pre-lowercased for matching.
    ///
    /// Lowercased once here rather than per keystroke. `FuzzyMatch` says
    /// outright that a large corpus wants preparation instead of repeated work,
    /// and a repository is a large corpus — this is the half of that preparation
    /// which belongs to whoever owns the files.
    ///
    /// ### Two strings, not four
    ///
    /// It used to store the URL and the absolute path as well, and they are the
    /// two largest of the four: the absolute path is the longest string, and a
    /// `URL` is a heap allocation of its own. At a hundred thousand files that is
    /// most of the index's memory spent on values derivable from the two that are
    /// left, so both are computed now and the root is carried instead — a struct
    /// field sharing one instance across every item rather than an allocation per
    /// item.
    ///
    /// This is what makes a large ceiling affordable; see `defaultResultCap`.
    public struct Item: Equatable {
        /// The root this item was walked under, so an absolute path can be
        /// rebuilt without storing one. Every item is a descendant of it by
        /// construction — the walk cannot produce anything else — which is what
        /// makes the reconstruction below exact rather than a guess.
        let root: URL

        /// Path relative to the index's root, which is what a picker shows and
        /// therefore what it matches against — highlight offsets have to index
        /// the string on screen.
        public let relativePath: String

        /// `relativePath`, lowercased once at build time.
        ///
        /// Not for the matcher, which lowercases its own candidate. This is for
        /// the cheap necessary-condition filter in front of it: a subsequence
        /// match requires every query character to appear somewhere, so a
        /// candidate missing one can be rejected without being scored. Over
        /// tens of thousands of files that is the difference between a picker
        /// that keeps up with typing and one that does not.
        public let lowercasedRelativePath: String

        /// Rebuilt by concatenation rather than `appendingPathComponent`, which
        /// treats its argument as one component and would have to be trusted not
        /// to escape the separators in a multi-segment relative path.
        public var path: String { root.path + "/" + relativePath }

        public var url: URL { URL(fileURLWithPath: path) }

        init(url: URL, root: URL) {
            self.root = root
            let relative = FileTabLabel.relativeOrAbbreviated(url, root: root)
            relativePath = relative
            lowercasedRelativePath = relative.lowercased()
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

    /// How many files a walk indexes before it stops.
    ///
    /// Deliberately far past any real tree. The ceiling exists to bound a
    /// pathological case — a root pointed at a filesystem, a directory of
    /// generated files — and not to ration a reader's own home directory, which
    /// the first ceiling did: fifty thousand was reached by an ordinary home and
    /// the picker then ranked against a fraction of it, saying so in a corner.
    ///
    /// Affordable because an item is two strings and a shared root rather than
    /// four strings and a URL. At this ceiling the index costs on the order of
    /// eighty megabytes, and only for someone who actually has half a million
    /// files under their root; a hundred thousand costs a sixth of that.
    ///
    /// A large ceiling is only usable alongside the presenter keeping the index
    /// between opens — a walk this size is not something to do while a reader
    /// waits for a field.
    public static let defaultResultCap = 500_000

    /// How many files arrive in one batch.
    ///
    /// Large enough that the bookkeeping is noise against the walking, small
    /// enough that a reader sees the corpus grow rather than appear.
    public static let defaultBatchSize = 5_000

    /// Walk a root and index what is under it.
    ///
    /// **Reports as it goes.** A tree of half a million files takes tens of
    /// seconds to enumerate, and a picker that waits for the end of that is a
    /// picker nobody can type into. `onBatch` receives each batch as it is
    /// found, so a caller can rank against a corpus that is still growing; the
    /// return value is the whole thing, so a caller that does not care passes
    /// nothing and reads the result.
    ///
    /// - Parameters:
    ///   - depthCap: how deep to descend. A guard against a pathological tree
    ///     rather than a policy — twelve is past anything a person navigates.
    ///   - resultCap: how many files to index before stopping, reported through
    ///     `wasTruncated`.
    ///   - batchSize: how many files to collect before reporting a batch.
    ///   - onBatch: called with each batch, on the walking thread. Batches are
    ///     disjoint and in walk order; concatenating them gives `items`.
    public static func build(
        root: URL,
        skipping skipList: Set<String> = defaultSkipList,
        depthCap: Int = 12,
        resultCap: Int = defaultResultCap,
        batchSize: Int = defaultBatchSize,
        onBatch: (([Item]) -> Void)? = nil
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

        var items: [Item] = []
        var batch: [Item] = []
        var truncated = false

        // Breadth-first, over an explicit queue, and that is the reason this is
        // not `FileManager.enumerator` any more.
        //
        // The enumerator is depth-first, which is the wrong order for a walk
        // whose partial results are shown: it spends its first several seconds
        // inside whichever subtree happens to sort first, so a reader watching
        // the count climb sees tens of thousands of files from one corner of the
        // tree and none of the shallow ones they are most likely to want. Level
        // by level, everything near the root arrives first.
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0

        walk: while head < queue.count {
            let (directory, depth) = queue[head]
            head += 1

            // Hidden files are *not* skipped. Dotfiles are among the things most
            // worth opening — `.gitignore`, `.env`, a shell profile — and the
            // kind table was widened during pre-work specifically so they
            // resolve. The hidden directories that are genuinely noise are named
            // in the skip list, which is a more honest instrument than a blanket
            // flag.
            guard
                let entries = try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey,
                    ],
                    options: []
                )
            else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])

                if values?.isDirectory == true {
                    // Symlinked directories are not descended into, which is
                    // what `FileManager.enumerator` did before this and is the
                    // behaviour worth keeping: a link can point at an ancestor,
                    // and a walk that follows one does not terminate.
                    if values?.isSymbolicLink == true { continue }

                    // Skipping the descent rather than filtering afterwards is
                    // what makes the list cheap: `node_modules` is never read at
                    // all, rather than read and discarded.
                    if skipList.contains(entry.lastPathComponent) { continue }
                    if depth + 1 <= depthCap {
                        queue.append((entry, depth + 1))
                    }
                    continue
                }

                let item = Item(url: entry, root: root)
                items.append(item)
                batch.append(item)

                if batch.count >= batchSize {
                    onBatch?(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                if items.count >= resultCap {
                    truncated = true
                    break walk
                }
            }
        }

        if !batch.isEmpty { onBatch?(batch) }
        return FileTreeIndex(root: root, items: items, wasTruncated: truncated)
    }
}
