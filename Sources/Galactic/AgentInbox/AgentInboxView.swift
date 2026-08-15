import AppKit
import SwiftUI

/// The inbox modal: what is waiting to reach the agent, in the order it will go.
///
/// An in-window overlay rather than a panel — see `AgentInboxPresenter` for why,
/// and for how a host mounts this.
///
/// The reader's edits — reorder, pause, send by hand, delete — all drive queue
/// methods that have existed since the queue did, so nothing beneath this view
/// changed to make them work. The one exception is sending a chosen row, which
/// needed the consumer: it is the only object holding both the in-flight record
/// and the host that answers whether a prompt can be read at all.
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
            // The live half of the header is its own observing view: this one
            // watches the presenter, which republishes when the *choice* of
            // queue changes and not when that queue's contents do. Reading the
            // count from here left it showing whatever it said when the modal
            // opened, which was right until the first message drained.
            if let inbox = presenter.inbox {
                AgentInboxHeaderControls(
                    inbox: inbox,
                    onEmpty: { confirmEmpty(inbox) })
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
            AgentInboxList(
                inbox: inbox,
                consumer: presenter.consumer,
                presenter: presenter,
                maxHeight: Self.listMaxHeight)
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

    private func confirmEmpty(_ inbox: AgentInbox) {
        AgentInboxConfirm.run(
            presenter: presenter,
            message: "Discard everything waiting?",
            detail: "\(inbox.entries.count) message(s) will be deleted without "
                + "being sent. This cannot be undone.",
            confirmTitle: "Discard All",
            onConfirm: { inbox.removeAll() })
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

// MARK: - Confirmation

/// Destructive gestures in here ask first, through the same sheet every other
/// confirmation in both apps uses.
///
/// The Escape stand-down is the part worth knowing about: an `NSAlert` shown as
/// a window-modal sheet still dispatches its keys through `NSApp`, so without
/// this the presenter's own Escape monitor would read the reader's Cancel as
/// "close the inbox" and pull the modal out from under the question.
private enum AgentInboxConfirm {
    /// `SheetAlert` answers on the main thread but types its callbacks
    /// nonisolated, so the hops back are asserted rather than awaited — an
    /// `await` here would let the modal dismiss between the reader's click and
    /// the edit it asked for.
    @MainActor
    static func run(
        presenter: AgentInboxPresenter,
        message: String,
        detail: String,
        confirmTitle: String,
        onConfirm: @escaping @MainActor () -> Void
    ) {
        // Unreachable while the modal is on screen, since the modal is mounted
        // in a window. Refusing to act is still the right answer if it ever
        // happens: the alternative is destroying messages without asking.
        guard let window = SheetAlert.hostWindow() else { return }

        presenter.isConfirming = true
        SheetAlert.confirm(
            in: window,
            message: message,
            detail: detail,
            confirm: confirmTitle,
            onConfirm: {
                MainActor.assumeIsolated {
                    presenter.isConfirming = false
                    onConfirm()
                }
            },
            onCancel: {
                MainActor.assumeIsolated { presenter.isConfirming = false }
            })
    }
}

// MARK: - Header controls

/// The count and the empty-everything button, observing the queue directly.
private struct AgentInboxHeaderControls: View {
    @ObservedObject var inbox: AgentInbox
    let onEmpty: () -> Void

    var body: some View {
        if !inbox.isEmpty {
            Text("\(inbox.entries.count) waiting")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            AgentInboxGlyphButton(
                systemName: "trash",
                help: "Discard everything waiting",
                action: onEmpty)
        }
    }
}

// MARK: - The list

/// The rows, split out so the queue can be observed directly.
private struct AgentInboxList: View {
    @ObservedObject var inbox: AgentInbox
    let consumer: AgentInboxConsumer?
    let presenter: AgentInboxPresenter
    let maxHeight: CGFloat

    @State private var notice: Notice?

    /// What a hand-sent message did, said back to the reader.
    ///
    /// Held here rather than announced and forgotten because the interesting
    /// outcomes are the quiet ones: a refusal writes nothing and a row that
    /// stays put looks identical to a click that missed.
    private struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let tint: Color

        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if inbox.isEmpty {
                empty
            } else {
                list
            }
            if let notice {
                noticeStrip(notice)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: notice)
        // Clears itself, and re-arms from scratch each time a new outcome
        // arrives — `task(id:)` cancels the pending clear when the id changes,
        // so a second send cannot be wiped by the first one's timer.
        .task(id: notice?.id) {
            guard notice != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private var empty: some View {
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
    }

    /// A `List` rather than the `ScrollView` this began as, purely for
    /// `onMove`: reordering is what the reader means by dragging a row, and
    /// `AgentInbox.move(fromOffsets:toOffset:)` was already written to that
    /// exact signature. The styling below is what it costs to keep a `List`
    /// looking like the card it sits in.
    private var list: some View {
        List {
            ForEach(inbox.entries) { entry in
                AgentInboxRow(
                    entry: entry,
                    showsTopDivider: entry.id != inbox.entries.first?.id,
                    onTogglePause: { togglePause(entry) },
                    onSendNow: { sendNow(entry) },
                    onDelete: { confirmDelete(entry) })
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .onMove { source, destination in
                inbox.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .frame(maxHeight: maxHeight)
    }

    private func noticeStrip(_ notice: Notice) -> some View {
        HStack(spacing: 6) {
            Text(notice.text)
                .font(.system(size: 11))
                .foregroundStyle(notice.tint)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(notice.tint.opacity(0.10))
        .transition(.opacity)
    }

    // MARK: Actions

    private func togglePause(_ entry: AgentInboxEntry) {
        inbox.setState(entry.state == .paused ? .ready : .paused, for: entry.id)
    }

    /// Sending by hand is allowed from any state, which is the point of it: the
    /// two rows most worth a manual push are exactly the ones the drain will
    /// not touch on its own.
    private func sendNow(_ entry: AgentInboxEntry) {
        guard let consumer else {
            notice = Notice(
                text: "No agent session to send to.", tint: .orange)
            return
        }
        consumer.sendNow(id: entry.id) { outcome in
            switch outcome {
            case .delivered:
                notice = Notice(text: "Sent.", tint: .green)
            case .refused:
                notice = Notice(
                    text: "That send failed — the agent can't take a message "
                        + "right now. It is still waiting here.",
                    tint: .orange)
            case .unconfirmed:
                notice = Notice(
                    text: "That send failed — the agent never confirmed it. "
                        + "It may still have arrived, so check before sending "
                        + "again.",
                    tint: .orange)
            }
        }
    }

    private func confirmDelete(_ entry: AgentInboxEntry) {
        AgentInboxConfirm.run(
            presenter: presenter,
            message: "Discard this message?",
            detail: "\(entry.sourceLabel) will be deleted without being sent. "
                + "This cannot be undone.",
            confirmTitle: "Discard",
            onConfirm: { inbox.remove(id: entry.id) })
    }
}

// MARK: - A row

private struct AgentInboxRow: View {
    let entry: AgentInboxEntry
    let showsTopDivider: Bool
    let onTogglePause: () -> Void
    let onSendNow: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTopDivider { Divider().padding(.leading, 16) }
            content
        }
    }

    private var content: some View {
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
        .contentShape(Rectangle())
        // An overlay rather than a member of the row's stack, so revealing the
        // controls cannot change the row's height or nudge the text under them.
        .overlay(alignment: .trailing) { if isHovering { actions } }
        .background(Color.primary.opacity(isHovering ? 0.06 : 0))
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// Send, hold, discard — left to right, destructive last and furthest from
    /// the pointer's resting path.
    private var actions: some View {
        HStack(spacing: 2) {
            AgentInboxGlyphButton(
                systemName: "paperplane",
                help: "Send this message now",
                action: onSendNow)
            AgentInboxGlyphButton(
                systemName: entry.state == .paused ? "play.fill" : "pause.fill",
                help: entry.state == .paused
                    ? "Let this message go again" : "Hold this message back",
                action: onTogglePause)
            AgentInboxGlyphButton(
                systemName: "trash",
                help: "Discard this message",
                action: onDelete)
        }
        // A scrim, so the controls stay legible over a message preview that
        // runs the full width of the row behind them.
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .padding(.trailing, 10)
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

// MARK: - A glyph button

/// A round glyph button on the pointing-hand idiom `AgentInboxIndicator`
/// already uses.
///
/// Local to this package on purpose. Both hosts ship a component like this and
/// neither is reachable from here — a shared view cannot import the app that
/// mounts it — so the choice is a small button here or a shared view that looks
/// like neither app.
private struct AgentInboxGlyphButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        Color.primary.opacity(isHovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { inside in
            isHovering = inside
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
