import AppKit
import SwiftUI

/// Compact find bar shown above a searchable WKWebView.
///
/// Identical UI on every surface (scrollback overlay, snapshot
/// reader, every artifact reader) — the controller's `webView`
/// determines what's actually being searched. Hides itself by
/// binding to `controller.isVisible`; surrounding chrome decides
/// when to flip that flag (typically a Cmd+F dispatcher).
///
/// Uses an AppKit-backed `FindTextFieldRepresentable` instead of
/// SwiftUI's `TextField` to avoid the latter's heavier cold-init
/// cost. The bar itself is hosted in a separate `NSPanel` (see
/// `FindBarPanel`) so AppKit's password-autofill heuristic walks
/// the panel's tiny view tree on first-responder transitions
/// instead of the parent window's full SwiftUI hierarchy.
public struct FindBarView: View {
    /// Type sizes for the bar's three pieces.
    ///
    /// Supplied by the host rather than derived here. One app scales its chrome
    /// through a user setting and the other does not, and a shared component
    /// should not know which — or carry a scaling feature on behalf of the app
    /// that has one. The defaults are that setting's values at scale 1.0, so a
    /// host with nothing to say gets what both apps rendered before.
    public struct Metrics {
        public var icon: CGFloat
        public var field: CGFloat
        public var matchCount: CGFloat

        public init(
            icon: CGFloat = 12,
            field: CGFloat = 10,
            matchCount: CGFloat = 11
        ) {
            self.icon = icon
            self.field = field
            self.matchCount = matchCount
        }

        public static let `default` = Metrics()
    }

    @ObservedObject var controller: WebViewFindController
    private let metrics: Metrics

    public init(
        controller: WebViewFindController,
        metrics: Metrics = .default
    ) {
        self.controller = controller
        self.metrics = metrics
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.icon))
                .foregroundColor(.secondary)

            FindTextFieldRepresentable(
                text: $controller.query,
                placeholder: "Find",
                font: NSFont.monospacedSystemFont(
                    ofSize: metrics.field,
                    weight: .regular
                ),
                textColor: .labelColor,
                onSubmit: { controller.next() },
                onShiftSubmit: { controller.prev() },
                onCancel: { controller.isVisible = false }
            )
            .frame(minWidth: 160)

            Text(matchLabel)
                .font(.system(size: metrics.matchCount, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            // Up arrow always walks visually UP. In forward
            // mode (artifact / snapshot readers) that maps to
            // controller.prev(); in reverse mode (scrollback,
            // where the JS pipeline iterates from the most
            // recent match back through history) it maps to
            // controller.next(). Icon position stays fixed —
            // up on the left, down on the right — to match
            // every other macOS find UI.
            Button(action: walkUpAction) {
                Image(systemName: "chevron.up")
                    .font(.system(size: metrics.icon))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            // ⇧↩ is also handled inside the text field's
            // doCommandBy: when focus is in the field. This
            // shortcut covers the case where focus has drifted
            // elsewhere (e.g., after a click outside).
            .keyboardShortcut(.return, modifiers: .shift)
            .help(walkUpHelp)

            Button(action: walkDownAction) {
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.icon))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help(walkDownHelp)

            Button(action: { controller.isVisible = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.icon))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Tertiary fallback for Esc — text field handles it
            // first via cancelOperation:, AppKit-level Esc
            // monitors in the parent views (scrollback overlay,
            // artifact reader) handle it as belt-and-suspenders.
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(radius: 4, y: 2)
        )
    }

    private var matchLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return "No matches" }
        return "\(controller.matchIndex + 1) "
            + "of \(controller.matchCount)"
    }

    /// Action for the up-arrow button. The button always walks
    /// visually UP; which controller method that corresponds to
    /// depends on whether the surface iterates forward or
    /// reverse. The JS pipeline's reverseMode flips next/prev's
    /// step direction, so calling next in a reverse-mode
    /// controller actually walks UP.
    private func walkUpAction() {
        if controller.reverse {
            controller.next()
        } else {
            controller.prev()
        }
    }

    /// Action for the down-arrow button — symmetric to walkUp.
    private func walkDownAction() {
        if controller.reverse {
            controller.prev()
        } else {
            controller.next()
        }
    }

    /// Tooltip on the up-arrow button. The shortcut hint
    /// reflects which keyboard chord triggers the same motion
    /// from the field: in forward mode walking up is the
    /// secondary action (Shift+Return), in reverse mode it's
    /// the primary action (Return).
    private var walkUpHelp: String {
        controller.reverse
            ? "Next match (↩)"
            : "Previous match (⇧↩)"
    }

    /// Tooltip on the down-arrow button — symmetric to walkUp.
    private var walkDownHelp: String {
        controller.reverse
            ? "Previous match (⇧↩)"
            : "Next match (↩)"
    }
}
