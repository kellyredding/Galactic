import Foundation

/// What a tab is called, at every width it might have to fit.
///
/// Returns tiers widest-first for a `ViewThatFits`, so the strip picks the most
/// informative label that will fit rather than truncating one label badly. The
/// mechanism already exists twice in Galaxy — a session row fits over
/// pre-built tiers, and the transcript reader squashes a home prefix — and this
/// is those two ideas generalised for a strip that re-measures as tabs open.
///
/// **A caution for whoever draws these.** `ViewThatFits` re-measures constantly
/// here, and it is the mechanism that carried the sliding-tab bug fixed in
/// `690b2ef`: no ambient animation may reach a view using it, in particular
/// nothing setting a repeating curve on the transaction.
public enum FileTabLabel {

    /// The most tiers `tiers(for:root:siblings:)` can return.
    ///
    /// Read by the strip, which needs a **fixed** number of `ViewThatFits`
    /// children — a `ForEach` inside one is a single child, so the slots have to
    /// be spelled out. A fifth tier added here without this number moving would
    /// simply never be offered, and the label would be one notch wider than it
    /// had to be with nothing failing. `FileTabLabelTests` pins the two together.
    public static let tierCount = 4

    /// Labels for one tab, widest first.
    ///
    /// - Parameters:
    ///   - url: the file this tab holds.
    ///   - root: the browsing root, so a file under it loses that prefix before
    ///     anything else is given up. A file outside it keeps an absolute path,
    ///     shortened at the home directory.
    ///   - siblings: every other open file. Consulted for one thing only —
    ///     whether the bare filename is ambiguous, in which case it is not
    ///     offered. A strip showing two tabs both reading `index.ts` has told
    ///     the reader nothing.
    public static func tiers(
        for url: URL,
        root: URL?,
        siblings: [URL] = []
    ) -> [String] {
        let relative = relativeOrAbbreviated(url, root: root)
        let others = siblings.filter { $0.path != url.path }

        var candidates = [relative]

        // Offered only when it still tells two tabs apart. `web/` and `worker/`
        // both squash to `w/`, so the same guard the bare filename needs
        // applies one tier up — otherwise the strip narrows into two labels
        // that read identically, which is worse than either staying wide.
        let squashed = squashingFolders(relative)
        let squashCollides = others.contains {
            squashingFolders(relativeOrAbbreviated($0, root: root)) == squashed
        }
        if !squashCollides { candidates.append(squashed) }

        candidates.append(parentAndFilename(relative))

        // The bare filename, on the same condition. Two tabs both reading
        // `index.ts` have told the reader nothing.
        let filename = url.lastPathComponent
        let filenameCollides = others.contains {
            $0.lastPathComponent == filename
        }
        if !filenameCollides { candidates.append(filename) }

        // Sorted by width rather than trusted to be in order. `models/user.rb`
        // is *narrower* than `src/models/user.rb` and *wider* than
        // `s/m/user.rb`, so the informative ordering and the width ordering are
        // not the same one — and `ViewThatFits` takes the first that fits, so a
        // list out of width order silently skips a label that would have fit.
        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    /// The label for a tab too narrow for any tier, which is always the
    /// filename.
    ///
    /// **Separate from the tiers because the collision guard must not reach
    /// here, and that is a deliberate reversal.** Above this width, withholding
    /// an ambiguous filename is right: two tabs reading `index.ts` have said
    /// nothing, and a path that distinguishes them is worth the room. At the
    /// floor there is no room to be worth, and the choice is between two labels
    /// that are both ambiguous — so it goes to the one that is ambiguous about
    /// *which* file rather than about *what kind of thing* it is.
    ///
    /// The failure this replaces: two tabs reading `S/k/…S.md` and `S/k/…E.md`.
    /// Middle-truncating a path keeps the squashed folders the two tabs have in
    /// common and cuts away the filename that tells them apart — it preserves
    /// exactly the half with no information in it. Paired with tail truncation
    /// at the call site, the head of the name survives instead, which is the
    /// part a reader scans.
    public static func floor(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Relative to the root when under it; otherwise absolute with the home
    /// directory shortened to `~`.
    static func relativeOrAbbreviated(_ url: URL, root: URL?) -> String {
        if let root,
           let relative = FilePaths.relativePath(of: url, under: root)
        {
            return relative
        }
        let home = NSHomeDirectory()
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    /// Every directory down to its first character, filename intact.
    ///
    /// `src/models/user.rb` becomes `s/m/user.rb`. The shape of the path
    /// survives — how deep it is, and roughly where — which is most of what a
    /// reader is reading it for once they already know the file.
    static func squashingFolders(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count > 1 else { return path }
        let filename = parts.removeLast()
        let squashed = parts.map { part -> String in
            // A leading dot is the identifying character of a dotfile
            // directory, so `.github` squashes to `.g` rather than to `.`.
            guard let first = part.first else { return part }
            if first == ".", part.count > 1 {
                return String(part.prefix(2))
            }
            return String(first)
        }
        return (squashed + [filename]).joined(separator: "/")
    }

    /// The immediate directory and the filename, taken from the *relative*
    /// path rather than from the URL.
    ///
    /// Asking the URL would reach outside the root and produce a label wider
    /// than the tier above it — a file sitting at the root came back as
    /// `project/a.rb` when the widest tier was already just `a.rb`.
    static func parentAndFilename(_ relative: String) -> String {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return relative }
        return parts.suffix(2).joined(separator: "/")
    }
}
