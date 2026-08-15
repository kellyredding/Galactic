import AppKit
import SwiftUI

/// The inbox modal: what is waiting to reach the agent, in the order it will go.
///
/// An in-window overlay rather than a panel — see `AgentInboxPresenter` for why,
/// and for how a host mounts this.
///
/// Ships read-only. `move`, `setState` and `remove` exist on the queue from day
/// one, so reordering, pausing and deleting are additions to this view rather
/// than changes to anything beneath it.
public struct AgentInboxView: View {
    @ObservedObject private var presenter: AgentInboxPresenter

    private static let cardWidth: CGFloat = 620
    private static let listMaxHeight: CGFloat = 520

    /// The modal a host mounts, on the shared presenter.
    ///
    /// Two initialisers rather than one with a default, for the language reason
    /// `CheatSheetView` documents: a default argument expression is read in a
    /// nonisolated context whatever the initialiser's isolation, so `= .shared`
    /// cannot name main-actor state, and reading it in the body can.
    @MainActor
    public init() {
        self.presenter = .shared
    }

    /// Injected, for a preview or a test wanting a presenter of its own.
    public init(presenter: AgentInboxPresenter) {
        self.presenter = presenter
    }

    public var body: some View {
        ZStack {
            scrim
            card
        }
        .onDisappear { presenter.restoreFocus() }
    }

    private var scrim: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 30, y: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            Text("Agent Inbox")
                .font(.system(size: 15, weight: .medium))
            Spacer()
            if let inbox = presenter.inbox, !inbox.isEmpty {
                Text(
                    "\(inbox.entries.count) waiting"
                )
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Text("esc")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let inbox = presenter.inbox {
            // Observed as its own object rather than read through the
            // presenter, so a message draining while the reader watches leaves
            // the list. The queue moves on its own; a snapshot here would go
            // quietly wrong the moment a turn ended.
            AgentInboxList(inbox: inbox, maxHeight: Self.listMaxHeight)
        } else {
            // Distinct from an empty queue, and worth the separate wording. A
            // reader seeing "nothing waiting" concludes their message was sent;
            // a reader seeing this knows it is being held because there is
            // nowhere to send it yet.
            message(
                "No agent session",
                detail: "Messages composed now will wait here until one starts."
            )
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// The rows, split out so the queue can be observed directly.
private struct AgentInboxList: View {
    @ObservedObject var inbox: AgentInbox
    let maxHeight: CGFloat

    var body: some View {
        if inbox.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing waiting")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Messages you send while the agent is busy queue up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(inbox.entries.enumerated()), id: \.element.id)
                    { index, entry in
                        if index > 0 { Divider().padding(.leading, 16) }
                        AgentInboxRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }
}

private struct AgentInboxRow: View {
    let entry: AgentInboxEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.sourceLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if entry.delivery == .standalone {
                    tag("on its own", tint: .secondary)
                }
                stateTag
                Spacer()
                Text(age)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text(preview)
                .font(.system(size: 12))
                .foregroundStyle(entry.state == .ready ? .primary : .secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var stateTag: some View {
        switch entry.state {
        case .ready:
            EmptyView()
        case .paused:
            tag("paused", tint: .secondary)
        case .stalled:
            // The attempt count is the whole story of this row, so it is on the
            // badge rather than hidden behind a tooltip: a reader deciding what
            // to do about a stalled message needs to know it was tried, and how
            // often, before they decide to send it again by hand.
            tag("unconfirmed ×\(entry.attempts)", tint: .orange)
        }
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// First line, trimmed. The body can run to tens of thousands of characters
    /// — a scrollback selection routinely does — and a row is for recognising a
    /// message, not reading it.
    private var preview: String {
        let flattened = entry.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return flattened.count > 220
            ? String(flattened.prefix(220)) + "…"
            : flattened
    }

    private var age: String {
        let seconds = Int(Date().timeIntervalSince(entry.enqueuedAt))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
