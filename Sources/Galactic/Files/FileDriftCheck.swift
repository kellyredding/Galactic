import Foundation

/// Whether a file on disk still matches what was read.
///
/// Asked once per commented file, at send time, and not before. A reader
/// reviewing a file the agent is editing will see it change constantly; saying
/// so while they type would be noise, and noise is how a marker stops being
/// read. What matters is whether the quote in the review still describes the
/// file the agent is about to look at.
public enum FileDriftCheck {

    /// Stat first, and read only when the stat disagrees.
    ///
    /// A bare `touch` moves the modification date without changing a byte, and
    /// a build step that rewrites a file with identical content does the same.
    /// Reporting drift for either would teach the reader to ignore the marker,
    /// so a moved stat is treated as a reason to look rather than as an answer.
    ///
    /// A file that has become unreadable — deleted, renamed, permissions
    /// changed — counts as drifted. The quote is still true about what was
    /// read; what is no longer true is that the path leads to it.
    public static func hasDrifted(_ file: ReaderFile) -> Bool {
        // Through `ReaderFile.stat`, which reads the path rather than the URL —
        // `URL.resourceValues` caches per URL value, and this is the same URL
        // that was stat'd at load, so asking it again would answer with the
        // values being compared against and never report drift at all.
        guard let now = ReaderFile.stat(file.url) else { return true }

        let statLooksSame =
            now.byteSize == file.byteSize
            && now.modifiedAt == file.modifiedAt
        if statLooksSame { return false }

        // The stat moved, so the expensive question is now worth asking. An
        // image carries no content to compare, so its stat is the whole answer.
        if file.kind == .image { return true }

        guard let data = try? Data(contentsOf: file.url) else { return true }
        let current: String
        if let utf8 = String(data: data, encoding: .utf8) {
            current = utf8
        } else {
            current = String(data: data, encoding: .isoLatin1) ?? ""
        }
        return current != file.content
    }
}
