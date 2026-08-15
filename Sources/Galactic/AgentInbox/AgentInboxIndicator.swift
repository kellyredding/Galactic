import AppKit
import SwiftUI

/// An envelope, shown while a queue has anything in it.
///
/// Presence only, and deliberately no count. A number invites arithmetic — is
/// three bad? — when the only thing worth knowing is that something has not
/// gone yet. The modal answers everything else.
///
/// Coloured to match the surrounding text rather than green or red. Both hosts
/// already spend those two colours on agent-running and unread, and a queued
/// message is neither good news nor a problem: it is pending, and the colour
/// should say so.
///
/// Shared rather than drawn per host, because the parts that could drift are
/// the parts that carry the meaning — which glyph, which colour, and whether
/// there is a number. Placement is the host's, and differs: a terminal tab
/// corner, a sidebar title prefix, a tab strip's trailing edge.
///
/// Clickable only where it has room to be. Given an action it becomes a
/// button with a pointing-hand cursor; given none it is a plain glyph.
///
/// The distinction is about the space around it rather than its size. Sitting
/// over a tab's own hit area, a small target turns a near-miss on the tab into
/// an unwanted modal — so the corner placements stay inert. Given its own room
/// beside the tabs, an aimed click is unambiguous and the modal is worth
/// reaching that way.
public struct AgentInboxIndicator: View {
    @ObservedObject private var inbox: AgentInbox

    private let size: CGFloat
    private let tint: Color
    private let hoverTint: Color
    private let onOpen: (() -> Void)?

    @State private var hovering = false

    /// - Parameters:
    ///   - inbox: The queue to watch. Observed directly rather than through
    ///     whatever owns it, so a host holding many queues shows each one's
    ///     state against its own session.
    ///   - size: Point size for the glyph, so chrome of different scales can
    ///     match its neighbours.
    ///   - tint: The colour at rest. A host placing this among its own
    ///     controls should pass whatever those use when they are not the
    ///     current one — the rule being that it stays a *text* colour. Green
    ///     and red both already mean something else in these apps, and a
    ///     queued message is neither a warning nor an alert; it is pending.
    ///   - hoverTint: The colour under the pointer, which should be whatever
    ///     the host's *selected* control uses. The pair is the whole hover
    ///     affordance, and it is a colour rather than an opacity change so it
    ///     reads the same direction in both themes: a semantic text colour
    ///     brightens against a dark background and darkens against a light
    ///     one, where dimming would wash out in one of the two.
    ///   - onOpen: What a click does, when clicking is appropriate. Nil leaves
    ///     it inert — see the note above about hit areas — and leaves
    ///     `hoverTint` unused, since nothing hovers what cannot be pressed.
    public init(
        inbox: AgentInbox,
        size: CGFloat = 11,
        tint: Color = .secondary,
        hoverTint: Color = .primary,
        onOpen: (() -> Void)? = nil
    ) {
        self._inbox = ObservedObject(wrappedValue: inbox)
        self.size = size
        self.tint = tint
        self.hoverTint = hoverTint
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            if !inbox.isEmpty {
                if let onOpen {
                    Button(action: onOpen) { glyph }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            hovering = inside
                            // The affordance is mostly the cursor, matching
                            // how the cheat sheet's own small controls do it.
                            if inside {
                                NSCursor.pointingHand.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                } else {
                    glyph
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: inbox.isEmpty)
    }

    private var glyph: some View {
        Image(systemName: "envelope.fill")
            .font(.system(size: size))
            .foregroundStyle(hovering ? hoverTint : tint)
            .help(helpText)
            .contentShape(Rectangle())
            .transition(.opacity)
    }

    /// The count belongs here and not on screen: a reader hovering has already
    /// asked the question the glyph raised, and this is the cheapest place to
    /// answer it without spending the chrome.
    private var helpText: String {
        let count = inbox.entries.count
        let noun = "\(count) message\(count == 1 ? "" : "s") waiting to send"
        return onOpen == nil ? "\(noun) (⇧⌘I)" : "\(noun) — click to open (⇧⌘I)"
    }
}
