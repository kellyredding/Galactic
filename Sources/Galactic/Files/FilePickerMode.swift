import SwiftUI

/// The two ways the picker offers to find a file.
///
/// Named for what the reader is doing rather than for what is drawn. "Find" is
/// deliberately not one of them: the in-file find bar owns that word already,
/// and two unrelated things sharing it is worse than a plainer pair.
public enum FilePickerMode: CaseIterable, Equatable {
    /// Type, and pick from a ranked list. What ⌘T always opens.
    case search
    /// Walk a folder tree, and filter it in place.
    case browse

    public var title: String {
        switch self {
        case .search: return "Search"
        case .browse: return "Browse"
        }
    }
}

/// The picker's two modes, as two half-width tabs.
///
/// **Deliberately nothing like `FileTabStripView`.** That strip draws a variable
/// set of documents, so it wraps into rows and its pills give up path segments
/// as they crowd. This is a fixed pair of modes, so it is two equal halves with
/// an underline — and sharing the other look would make two different things
/// claim to be the same kind of thing.
///
/// The underline spans the whole half rather than the label, which is what makes
/// the pair read as one control rather than as two words with a mark under one.
struct FilePickerModeTabs: View {
    let selected: FilePickerMode
    let onSelect: (FilePickerMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FilePickerMode.allCases, id: \.self) { mode in
                tab(mode)
            }
        }
    }

    private func tab(_ mode: FilePickerMode) -> some View {
        let isSelected = mode == selected
        return VStack(spacing: 0) {
            Text(mode.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            // Drawn in both states rather than conditionally, so selecting a
            // tab cannot change the strip's height and nudge everything below
            // it by a point.
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(mode) }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
