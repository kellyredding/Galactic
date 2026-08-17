import Foundation

/// A file read from disk, frozen at the moment it was read.
///
/// Frozen because the agent that wrote it is still working. Neither precedent
/// helps: a scrollback buffer cannot change, and a stored artifact carries a
/// content hash and a staleness column because it is a copy. A live file has
/// neither, so the content here is the ground truth a note quotes and the
/// path:line beside it is a hint — `FileDriftCheck` is what notices the two
/// have come apart, and says so at the moment it matters rather than
/// continuously.
public struct ReaderFile: Equatable {
    public let url: URL
    /// The whole file as text. Empty for `.image`, which is rendered from its
    /// path rather than from a string.
    public let content: String
    public let kind: FileKind
    public let byteSize: Int
    /// Modification time when this was read, for the cheap half of the drift
    /// check — a stat that has not moved cannot have changed content.
    public let modifiedAt: Date
    public let loadedAt: Date

    /// Why a file could not be opened.
    ///
    /// Three cases rather than one, because a host answers them differently: a
    /// binary file is handed to the system, an oversized one is reported with
    /// its numbers so the reader knows by how much, and an unreadable one is
    /// just reported.
    public enum LoadFailure: Error, Equatable {
        /// Missing, or refused by the filesystem.
        case unreadable
        case tooLarge(byteSize: Int, cap: Int)
        /// Binary, and not an image — so nothing here can render it.
        case notText
    }

    /// How much of the head is examined for the binary sniff.
    ///
    /// A heuristic, deliberately. A NUL byte beyond this window is not found,
    /// which is the trade every tool that does this makes: reading further to
    /// be certain costs the whole file on every open, and a text file with a
    /// stray NUL past eight kilobytes is rarer than a large file is common.
    static let sniffWindow = 8_192

    /// Size and modification date, read without going through `URL`.
    ///
    /// `URL.resourceValues(forKeys:)` **caches**, and the cache belongs to the
    /// URL value rather than to the call. Since the same URL is stored on this
    /// struct and asked again by `FileDriftCheck`, going through it would
    /// answer the second question with the first question's values — so drift
    /// would never be found, and the check would look like it worked. Asked of
    /// the path instead, which caches nothing.
    static func stat(_ url: URL) -> (byteSize: Int, modifiedAt: Date)? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let size = attrs[.size] as? Int
        else { return nil }
        let modified = attrs[.modificationDate] as? Date ?? Date.distantPast
        return (size, modified)
    }

    public static func load(
        url: URL,
        capOverride: Int? = nil
    ) throws -> ReaderFile {
        // Resolved from the name alone first, and only to answer two questions
        // before anything is read: how big is too big, and is this an image —
        // which is read from its path and never as a string.
        let namedKind = FileKind.resolve(filename: url.lastPathComponent)

        guard let stat = Self.stat(url) else { throw LoadFailure.unreadable }
        let byteSize = stat.byteSize
        let modifiedAt = stat.modifiedAt

        // Stat before reading. A cap checked afterwards has already paid the
        // cost it exists to avoid.
        let cap = capOverride ?? Int(namedKind.defaultSizeCap)
        guard byteSize <= cap else {
            throw LoadFailure.tooLarge(byteSize: byteSize, cap: cap)
        }

        if namedKind == .image {
            return ReaderFile(
                url: url, content: "", kind: .image, byteSize: byteSize,
                modifiedAt: modifiedAt, loadedAt: Date()
            )
        }

        guard let data = try? Data(contentsOf: url) else {
            throw LoadFailure.unreadable
        }

        // The whole render policy, in one check: text-ness decides, not the
        // extension. An unknown suffix holding text opens as source, and a
        // `.txt` that is secretly a database does not.
        if data.prefix(sniffWindow).contains(0) {
            throw LoadFailure.notText
        }

        // UTF-8 first, then latin-1 — which cannot fail, since every byte maps
        // to a scalar. So one stray byte does not lose a file that is
        // otherwise perfectly readable, the same call `galaxy-diff` makes.
        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else {
            content = String(data: data, encoding: .isoLatin1) ?? ""
        }

        // Asked again with the first line, because `.jsonl` is the one
        // extension whose reader depends on what is inside it rather than on
        // what it is called.
        let firstLine = content.prefix(while: { $0 != "\n" })

        return ReaderFile(
            url: url,
            content: content,
            kind: FileKind.resolve(
                filename: url.lastPathComponent,
                firstLine: firstLine.isEmpty ? nil : String(firstLine)
            ),
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            loadedAt: Date()
        )
    }
}
