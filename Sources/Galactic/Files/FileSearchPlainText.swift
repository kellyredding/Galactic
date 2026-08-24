import Foundation

/// A search run as plain text.
///
/// The results tab is a real file on disk, and this is what is written into it.
/// The page a reader sees is rendered separately from the run held in memory, so
/// that a theme change re-renders in the new appearance rather than serving
/// baked colours — which means these bytes are what everything *other* than
/// that reader gets: Copy Path and open elsewhere, a relaunch that still has the
/// file but not the run, `grep` over it.
///
/// Shaped like the reference implementation's buffer, and like compiler output,
/// so `path:line:` is greppable and a line can be pasted into a review.
public enum FileSearchPlainText {

    public static func render(run: FileSearchRun) -> String {
        var out: [String] = []

        if !run.wasRootIndexed {
            out.append("This folder is not indexed yet, so nothing was searched.")
        } else {
            let mode = run.query.isCaseSensitive
                ? "case sensitive" : "case insensitive"
            out.append(
                "Searching \(run.filesConsidered.formatted()) files for "
                    + "\"\(run.query.text)\" (\(mode))"
            )
        }

        switch run.truncation {
        case .matchCap(let cap):
            out.append(
                "Stopped at \(cap.formatted()) matches — "
                    + "\(run.filesScanned.formatted()) of "
                    + "\(run.filesConsidered.formatted()) files were read."
            )
        case .fileCap(let cap):
            out.append(
                "Some files had more than \(cap.formatted()) matches; only "
                    + "the first \(cap.formatted()) of each are shown."
            )
        case nil:
            break
        }

        if run.wasRootIndexed, !run.skippedNames.isEmpty {
            out.append("Not searched: \(run.skippedNames.joined(separator: ", "))")
        }

        if run.wasRootIndexed, run.files.isEmpty, run.truncation == nil {
            out.append("No matches.")
        }

        for file in run.files {
            out.append("")
            out.append("\(file.relativePath):")
            for (index, block) in file.blocks.enumerated() {
                if index > 0 { out.append("") }
                for line in block {
                    // The colon marks a matching line, as the gutter does in
                    // the rendered page. Width four keeps ordinary files
                    // aligned without padding a six-digit line out of shape.
                    let number = String(line.line)
                    let pad = String(
                        repeating: " ", count: max(0, 4 - number.count)
                    )
                    let marker = line.isMatch ? ":" : " "
                    out.append("\(pad)\(number)\(marker) \(line.text)")
                }
            }
        }

        return out.joined(separator: "\n") + "\n"
    }
}
