import SwiftUI

/// The set on screen, above its tab strip, and what it holds.
///
/// Clicking the name opens the switcher. A dot beside it says another set is
/// holding notes that have not been sent — the one place a reader looking at
/// this set can learn that.
struct FileSetBar: View {
    @ObservedObject var group: FileSetGroup
    let onToggleSwitcher: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleSwitcher) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(group.selected.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if group.selected.origin == .agent {
                        Text("✦")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if group.otherSetsHoldNotes {
                        Circle()
                            .fill(green)
                            .frame(width: 6, height: 6)
                            .help("Another set has notes that have not been sent")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch file set")

            Spacer(minLength: 8)

            FileSetTotals(set: group.selected, green: green)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var green: Color {
        Color(SendBarGreen.color(isLight: colorScheme != .dark))
    }
}

/// Observes the set itself, so a file opened or a note written redraws the
/// count without the group having changed.
private struct FileSetTotals: View {
    @ObservedObject var set: FileSet
    let green: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(files).foregroundStyle(.secondary)
            if set.totalNoteCount > 0 {
                Text(" · ").foregroundStyle(.tertiary)
                Text(notes)
                    .fontWeight(.medium)
                    .foregroundStyle(green)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var files: String {
        switch set.fileCount {
        case 0: return "No files"
        case 1: return "1 file"
        default: return "\(set.fileCount) files"
        }
    }

    // `self.` is required: a computed body opening with `set` parses as a
    // setter.
    private var notes: String {
        self.set.totalNoteCount == 1
            ? "1 note" : "\(self.set.totalNoteCount) notes"
    }
}
