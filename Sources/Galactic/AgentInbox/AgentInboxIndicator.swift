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
/// Not clickable, and not a button. A small target in chrome turns an aimed
/// click into an unwanted modal, and clickability is easy to add later and
/// awkward to take away once someone's hand has learned it.
public struct AgentInboxIndicator: View {
    @ObservedObject private var inbox: AgentInbox

    private let size: CGFloat

    /// - Parameters:
    ///   - inbox: The queue to watch. Observed directly rather than through
    ///     whatever owns it, so a host holding many queues shows each one's
    ///     state against its own session.
    ///   - size: Point size for the glyph, so chrome of different scales can
    ///     match its neighbours.
    public init(inbox: AgentInbox, size: CGFloat = 11) {
        self._inbox = ObservedObject(wrappedValue: inbox)
        self.size = size
    }

    public var body: some View {
        Group {
            if !inbox.isEmpty {
                Image(systemName: "envelope.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .help(helpText)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: inbox.isEmpty)
    }

    /// The count belongs here and not on screen: a reader hovering has already
    /// asked the question the glyph raised, and this is the cheapest place to
    /// answer it without spending the chrome.
    private var helpText: String {
        let count = inbox.entries.count
        return "\(count) message\(count == 1 ? "" : "s") "
            + "waiting to send (⇧⌘I)"
    }
}
