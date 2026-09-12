import Combine
import SwiftUI

/// The Files surface: the set bar, and a pane for each set the reader has
/// visited, one of them in front.
///
/// **One pane per set, kept alive behind an opacity switch.** A reader that is
/// torn down rescues nothing, so rebuilding one reader on a set switch would
/// lose a half-written note whenever the incoming set is empty. A set's pane is
/// mounted on its first visit and stays until the set is deleted.
///
/// A host supplies the surface, the owner's group, whether this surface is the
/// one in front, and three publishers for the keystrokes its menu owns.
public struct FilesPaneView: View {

    private let surface: FilesSurface
    @ObservedObject private var group: FileSetGroup
    private let isVisibleSurface: Bool
    private let isObscuredByHost: () -> Bool
    private let findActivations: AnyPublisher<Void, Never>
    private let lineJumpActivations: AnyPublisher<Void, Never>
    private let searchActivations: AnyPublisher<Void, Never>
    private let emptyHint: String?

    @ObservedObject private var switcher = FileSetSwitcherPresenter.shared

    /// Every set shown since this view appeared, each with its pane mounted.
    @State private var visited: Set<String> = []

    public init(
        surface: FilesSurface,
        group: FileSetGroup,
        isVisibleSurface: Bool,
        isObscuredByHost: @escaping () -> Bool = { false },
        findActivations: AnyPublisher<Void, Never>,
        lineJumpActivations: AnyPublisher<Void, Never>,
        searchActivations: AnyPublisher<Void, Never>,
        emptyHint: String? = nil
    ) {
        self.surface = surface
        self.group = group
        self.isVisibleSurface = isVisibleSurface
        self.isObscuredByHost = isObscuredByHost
        self.findActivations = findActivations
        self.lineJumpActivations = lineJumpActivations
        self.searchActivations = searchActivations
        self.emptyHint = emptyHint
    }

    public var body: some View {
        VStack(spacing: 0) {
            FileSetBar(group: group) { surface.toggleSwitcher() }
            Divider()
            ZStack {
                ForEach(mountedSets, id: \.id) { set in
                    let showing = set.id == group.selectedID
                    FileSetPaneView(
                        surface: surface,
                        set: set,
                        isVisibleSurface: isVisibleSurface && showing,
                        isObscuredByHost: isObscuredByHost,
                        findActivations: findActivations,
                        lineJumpActivations: lineJumpActivations,
                        searchActivations: searchActivations,
                        emptyHint: emptyHint
                    )
                    .opacity(showing ? 1 : 0)
                    .allowsHitTesting(showing)
                }
            }
            // The animation lives inside the overlay: one on the stack would
            // reach the tab strip, which must never animate.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    // Gated on visibility for the reason the other panels are:
                    // a host mounts one of these per session.
                    if isVisibleSurface, switcher.isPresented {
                        FileSetSwitcherView().transition(.opacity)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.12), value: switcher.isPresented
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { visited.insert(group.selectedID) }
        .onChange(of: group.selectedID) { _, id in visited.insert(id) }
    }

    private var mountedSets: [FileSet] {
        group.sets.filter {
            visited.contains($0.id) || $0.id == group.selectedID
        }
    }
}
