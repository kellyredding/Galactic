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

    /// Labels for one tab, widest first — one for every folder that could be
    /// spelled out instead of initialled.
    ///
    /// **A tier per folder, not four tiers.** It used to offer the whole path,
    /// the path with every folder cut to its initial, the last folder plus the
    /// filename, and the filename — which is a cliff. A row with room left over
    /// could not buy anything with it, because the only upgrade on offer from
    /// `p/k/e/a/m/api_client.rb` was the entire path, and the leftover was never
    /// that big. So the room went unspent and the tab looked squashed while the
    /// row looked empty. Unwinding one folder at a time gives the fit something
    /// it can actually afford.
    ///
    /// Unwound from the **right**, because the folders nearest the file are the
    /// ones that say which file it is: `app/models/user.rb` and
    /// `spec/models/user.rb` differ at the left, but `a/m/user.rb` against
    /// `a/models/user.rb` is the step that starts telling you something.
    ///
    /// - Parameters:
    ///   - url: the file this tab holds.
    ///   - root: the browsing root, so a file under it loses that prefix before
    ///     anything else is given up. A file outside it keeps an absolute path,
    ///     shortened at the home directory.
    ///   - siblings: every other open file. Consulted for one thing only —
    ///     whether a label is ambiguous, in which case it is not offered. A strip
    ///     showing two tabs both reading `index.ts` has told the reader nothing.
    public static func tiers(
        for url: URL,
        root: URL?,
        siblings: [URL] = []
    ) -> [String] {
        // A document this package generated, whose path is storage rather than
        // meaning. Search results sit under a per-owner directory — a constant
        // in a single-session application and a session id in one with several
        // — so spelling the path out labels the same tab differently in each,
        // and in one of them with a raw identifier a reader cannot act on. The
        // name is the whole of what such a tab has to say.
        if url.path.hasPrefix(FileIndexPaths.root.path + "/") {
            return [url.lastPathComponent]
        }

        let relative = relativeOrAbbreviated(url, root: root)
        let others = siblings.filter { $0.path != url.path }

        var parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count > 1 else { return [relative] }
        let filename = parts.removeLast()
        let folders = parts

        // Widest first: everything spelled out, then one more folder initialled
        // each step, from the left inwards.
        var candidates: [String] = []
        for spelled in stride(from: folders.count, through: 0, by: -1) {
            let shown = folders.enumerated().map { index, folder in
                index >= folders.count - spelled ? folder : initial(of: folder)
            }
            candidates.append((shown + [filename]).joined(separator: "/"))
        }

        // The all-initials form goes only when it still tells two tabs apart.
        // `web/` and `worker/` both squash to `w/`, so two tabs would narrow into
        // labels that read identically — worse than either staying wide.
        if let allInitials = candidates.last,
            others.contains(where: {
                squashingFolders(relativeOrAbbreviated($0, root: root))
                    == allInitials
            })
        {
            candidates.removeLast()
        }

        // The bare filename, on the same condition.
        if !others.contains(where: { $0.lastPathComponent == filename }) {
            candidates.append(filename)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
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
        let squashed = parts.map(initial(of:))
        return (squashed + [filename]).joined(separator: "/")
    }

    /// A folder reduced to the character that identifies it.
    ///
    /// A leading dot is part of that identity, so `.github` becomes `.g` rather
    /// than a bare dot that could be anything.
    static func initial(of folder: String) -> String {
        guard let first = folder.first else { return folder }
        if first == ".", folder.count > 1 { return String(folder.prefix(2)) }
        return String(first)
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
