import AppKit
import SwiftUI

/// Height of one text-entry row's controls.
///
/// Shared by the label, the pills and the capture field, because the row aligns
/// on `.top` — which it must, so a wrapped second row of pills falls beneath the
/// first instead of dragging the whole stack off centre. Top alignment only
/// looks right if the three boxes are the same height, so this is what makes
/// them so rather than leaving it to each one's intrinsic size.
private let keystrokeRowHeight: CGFloat = 25

/// Width of the capture field, in both states.
///
/// Sized for "Press a key…" rather than "Add…" so the field keeps still when it
/// arms. A field that grew at the moment of being clicked would move out from
/// under the pointer.
private let keystrokeFieldWidth: CGFloat = 104

/// Lays subviews in rows, wrapping when a row fills, with every row pushed to
/// the trailing edge.
///
/// Needed because a plain `HStack` cannot wrap: it shrinks its children
/// instead, which is what broke a pill's label across two lines mid-word. Here
/// each subview is placed at its own ideal size and a row that will not fit
/// starts a new line, so a label never wraps — the pill does.
struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width

            if !row.indices.isEmpty, added > maxWidth {
                result.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width = added
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { result.append(row) }
        return result
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let laid = rows(for: subviews, maxWidth: maxWidth)
        guard !laid.isEmpty else { return .zero }
        let height =
            laid.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(laid.count - 1)
        let width = laid.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.maxX - row.width  // trailing-aligned
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

/// A capture field that records one keystroke and hands it back.
///
/// A rounded field, flush right, showing a placeholder until armed — reading
/// like the shortcut recorders in a system settings pane.
///
/// The local `NSEvent` monitor is the load-bearing choice. A local monitor only
/// sees events already routed to this app, so recording cannot claim a chord
/// system-wide — and a bare Return becomes recordable, which is exactly what
/// the `KeyboardShortcuts` package refuses to do, because it registers a real
/// global hotkey and a modifier-less global Return would be catastrophic.
///
/// Every captured event is consumed, so arming the field cannot also trigger
/// whatever the chord normally does in the app.
struct KeystrokeRecorder: View {
    var placeholder: String = "Add…"
    let onCapture: (Keystroke) -> Void
    var onRefusal: (String) -> Void = { _ in }

    @State private var isRecording = false
    @State private var isHovering = false
    @State private var monitor: Any?

    /// Border and text move together through the field's three states, so it
    /// reads as one affordance brightening rather than two things changing.
    ///
    /// Every colour is a semantic `NSColor`, which is what makes this correct in
    /// both themes with no light/dark branch — the system resolves each one
    /// against the active appearance.
    private var borderColor: Color {
        if isRecording { return .accentColor }
        return isHovering
            ? Color(NSColor.labelColor)
            : Color(NSColor.tertiaryLabelColor)
    }

    private var textColor: Color {
        if isRecording || isHovering { return Color(NSColor.labelColor) }
        return Color(NSColor.secondaryLabelColor)
    }

    var body: some View {
        Button {
            if isRecording { teardown() } else { arm() }
        } label: {
            Text(isRecording ? "Press a key…" : placeholder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(textColor)
                // Wide enough for the recording placeholder, which is the
                // longest thing this ever shows, and fixed so the field does
                // not resize under the pointer when it arms. The label sets no
                // horizontal padding of its own, so this width is the box.
                .frame(width: keystrokeFieldWidth)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(borderColor, lineWidth: isRecording ? 1.5 : 1)
                )
                // Matches the outer padding a pill carries for its removal
                // badge. Without it the two boxes have different heights, and
                // the row's `.top` alignment leaves the capsules sitting lower
                // than the field beside them.
                .padding(3)
                .frame(height: keystrokeRowHeight)
        }
        .buttonStyle(.plain)
        .help(
            isRecording
                ? "Press a keystroke, or Escape to cancel"
                : "Click, then press a keystroke to add it"
        )
        .onHover { inside in
            isHovering = inside
            // The field is a button that does not look like one until you are
            // over it, so the cursor is carrying most of the affordance.
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear {
            teardown()
            if isHovering { NSCursor.arrow.set() }
        }
    }

    private func arm() {
        isRecording = true
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keystroke = Keystroke(event: event)

            // 53 = Escape. Abandon without changing anything, so a field armed
            // by mistake is harmless.
            if event.keyCode == 53, keystroke.modifiers.isEmpty {
                DispatchQueue.main.async { teardown() }
                return nil
            }

            if keystroke == Keystroke.reservedMachineSubmit {
                DispatchQueue.main.async {
                    teardown()
                    onRefusal("⌃⌥⇧⌘Enter is reserved for automated prompts")
                }
                return nil
            }

            // A key with no DOM spelling cannot reach a WebView composer, so
            // accepting it would list a binding that silently does nothing —
            // which is how Ctrl+J once beeped instead of inserting a newline.
            guard keystroke.isBindable else {
                DispatchQueue.main.async {
                    teardown()
                    onRefusal("That key can't be bound here")
                }
                return nil
            }

            DispatchQueue.main.async {
                teardown()
                onCapture(keystroke)
            }
            return nil  // Consume: recording must not also perform the action.
        }
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

/// The keystrokes bound to one action: a wrapping column of pills, then the
/// capture field, both flush to the trailing edge.
///
/// Hovering a pill turns it destructive — translucent red fill, red border, and
/// a red ⊗ floated on its corner — and clicking it removes. The ⊗ is an overlay
/// rather than a sibling, so it claims no width: reserving room for it pushed
/// every label off-centre and squeezed pills until their text wrapped mid-word.
///
/// Removal is withheld from a lone keystroke, which is what makes an empty list
/// unreachable. That is not tidiness: a host's submit is typically reachable
/// only from a keydown handler, with no button and no menu item behind it, so an
/// empty submit list would leave a composer whose text could only be discarded,
/// and an empty newline list would make a multi-line entry impossible.
public struct KeystrokeListEditor: View {
    let label: String
    @Binding var keystrokes: [Keystroke]

    /// The sibling list and what to call it, so one keystroke cannot be
    /// recorded as meaning two things.
    ///
    /// The matcher tolerates a keystroke in both lists and breaks the tie
    /// towards submit, which is the right behaviour for settings that arrive
    /// without passing through here — hand-edited, or carried in from the
    /// keybindings file. It is the wrong thing to *offer*: the losing pill goes
    /// on being displayed while doing nothing, so the card ends up stating a
    /// binding the app does not honour.
    var siblingLabel: String?
    var sibling: Binding<[Keystroke]>?

    @State private var hovered: Keystroke?
    @State private var refusal: String?

    /// `siblingLabel` and `sibling` travel together: naming a sibling list is
    /// how a captured keystroke gets moved out of it rather than silently
    /// duplicated, and the label is what the refusal message calls it.
    public init(
        label: String,
        keystrokes: Binding<[Keystroke]>,
        siblingLabel: String? = nil,
        sibling: Binding<[Keystroke]>? = nil
    ) {
        self.label = label
        self._keystrokes = keystrokes
        self.siblingLabel = siblingLabel
        self.sibling = sibling
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // .top so the first row of pills lines up with the capture field
            // rather than drifting as later rows wrap beneath it.
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .frame(
                        width: 66,
                        height: keystrokeRowHeight,
                        alignment: .leading
                    )

                // No spacing of its own: each pill carries 3pt of padding that
                // both separates it and makes its floated ⊗ clickable.
                TrailingFlowLayout(spacing: 0, lineSpacing: 0) {
                    ForEach(keystrokes, id: \.self) { pill($0) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                KeystrokeRecorder(
                    onCapture: { captured in
                        refusal = nil
                        if let sibling,
                           sibling.wrappedValue.contains(captured) {
                            // Taking the sibling's last keystroke would leave
                            // it empty, which the card must never produce — an
                            // empty submit list has no save button behind it, so
                            // composed text could only be discarded. Say so
                            // instead, and let the choice be deliberate.
                            guard sibling.wrappedValue.count > 1 else {
                                refusal =
                                    "\(captured.displayLabel) is the only "
                                    + "\(siblingLabel ?? "other") keystroke — "
                                    + "add another there first"
                                return
                            }
                            // Moved rather than refused: the tie-break already
                            // gives submit the key, so moving it is what makes
                            // the display agree with what the app was going to
                            // do anyway. The pill leaving the row above is the
                            // feedback; a message would only restate it.
                            sibling.wrappedValue.removeAll { $0 == captured }
                        }
                        // Re-adding an existing chord is a no-op rather than a
                        // duplicate that could never match twice.
                        if !keystrokes.contains(captured) {
                            keystrokes.append(captured)
                        }
                    },
                    onRefusal: { refusal = $0 }
                )
            }

            if let refusal {
                Text(refusal)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }

    private func pill(_ keystroke: Keystroke) -> some View {
        let isRemovable = keystrokes.count > 1
        let isHot = hovered == keystroke && isRemovable

        return Text(keystroke.displayLabel)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(isHot ? .red : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    isHot
                        ? Color.red.opacity(0.15)
                        : Color(NSColor.controlColor)
                )
            )
            .overlay(
                Capsule().stroke(
                    isHot
                        ? Color.red.opacity(0.85)
                        : Color(NSColor.separatorColor),
                    lineWidth: isHot ? 1 : 0.5
                )
            )
            .overlay(alignment: .topTrailing) {
                if isHot {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .offset(x: 3, y: -3)
                }
            }
            // The whole pill removes on click — the ⊗ is a signal, not a
            // target. This padding is what makes that true at the corner: the
            // badge is offset beyond the capsule, and SwiftUI does not
            // hit-test an overlay outside its parent's frame, so without it the
            // pixels that look most like a delete button would miss. The
            // padding also supplies the gap between pills, which is why the
            // flow layout adds none of its own.
            .padding(3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside ? keystroke : nil
                if inside, isRemovable {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onTapGesture {
                guard isRemovable else { return }
                refusal = nil
                NSCursor.arrow.set()
                keystrokes.removeAll { $0 == keystroke }
            }
            .help(
                isRemovable
                    ? "Click to remove \(keystroke.displayLabel)"
                    : "\(keystroke.displayLabel) — at least one is required"
            )
    }
}
