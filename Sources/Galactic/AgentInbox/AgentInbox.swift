import Combine
import Foundation

/// The messages waiting to reach one agent session, in the order they will go.
///
/// The queue owns three things and deliberately no more: what is waiting, what
/// order it is in, and what happened to each attempt. It does not know how a
/// message is delivered, whether the agent can read one right now, or that a
/// terminal exists — a consumer asks it for work and reports back, and those
/// are the only two things anyone tells it.
///
/// Position is the array's order rather than a stored field, so a reorder
/// cannot disagree with the order things actually go out in. There is no
/// sort, no priority, and no timestamp comparison anywhere in here: a reader
/// who drags a row expects that to be the answer.
///
/// In-memory by design. Entries do not survive the app, and a quit warning
/// covers the deliberate case — which sidesteps the sharpest difference
/// between the two hosts, one of whose stores is open to any process while the
/// other is reachable only through a running app's socket.
///
/// Not actor-isolated, deliberately. Both hosts are plain `ObservableObject`s
/// driving SwiftUI from the main queue without saying so, and this is the same
/// kind of object as those. Isolating it would oblige each host to convert
/// proven session code before it could hold one — the opposite of a mechanism
/// a host adopts by supplying values. Annotating the hosts is worth doing, and
/// worth doing on its own terms rather than as this feature's side effect.
public final class AgentInbox: ObservableObject {

    @Published public private(set) var entries: [AgentInboxEntry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Whether anything here could go out if the agent were ready.
    ///
    /// Distinct from `isEmpty`: a queue holding only paused and stalled rows is
    /// not empty, and a host that treats the two as the same question ends up
    /// waking a consumer that has nothing to do, forever.
    public var hasSendableWork: Bool {
        entries.contains { $0.state == .ready }
    }

    // MARK: - Producing

    /// Add a message to the back of the queue.
    ///
    /// The whole producer-facing surface. There is no send-now variant on
    /// purpose — an idle send is an enqueue the consumer picks up in the same
    /// frame, and offering a second path is offering a call site the chance to
    /// bypass the queue on the day the queue is the thing keeping it safe.
    public func enqueue(_ entry: AgentInboxEntry) {
        entries.append(entry)
    }

    // MARK: - Consuming

    public func nextUnit() -> AgentInboxUnit? {
        AgentInboxSelection.nextUnit(from: entries)
    }

    /// The unit landed. Its entries leave.
    ///
    /// Matched by id rather than by position, because the queue may have been
    /// reordered — or added to — while the unit was in flight. Removing the
    /// head on the strength of it having been the head when we handed it out
    /// would retire whatever happens to be there now.
    public func complete(_ unit: AgentInboxUnit) {
        let delivered = Set(unit.entryIDs)
        entries.removeAll { delivered.contains($0.id) }
    }

    /// The unit did not report acceptance.
    ///
    /// Entries stay and their attempt count rises; past the ceiling they go
    /// `.stalled` rather than being handed out again. The ceiling is the point:
    /// the failure being counted here is a missing *report*, which is
    /// indistinguishable from a message that arrived and was never confirmed,
    /// so an unbounded retry would send the agent the same thing repeatedly and
    /// call it recovery.
    public func recordAttemptFailure(_ unit: AgentInboxUnit, ceiling: Int) {
        let attempted = Set(unit.entryIDs)
        for index in entries.indices where attempted.contains(entries[index].id)
        {
            entries[index].attempts += 1
            if entries[index].attempts >= ceiling {
                entries[index].state = .stalled
            }
        }
    }

    // MARK: - The reader's edits

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Change one entry's state.
    ///
    /// Returning a stalled entry to `.ready` also clears its attempt count.
    /// The stall *is* the record of those attempts, and a reader discharging it
    /// is asking for a real retry — leaving the count at the ceiling would make
    /// the gesture nearly inert, re-stalling the entry after a single failure.
    ///
    /// This is the one place the ceiling can be reset, and it takes a
    /// deliberate human action every time. The consumer can still never talk
    /// itself into another attempt, which is the loop the ceiling exists to
    /// stop.
    public func setState(_ state: AgentInboxEntry.State, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        if state == .ready, entries[index].state == .stalled {
            entries[index].attempts = 0
        }
        entries[index].state = state
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Empty the queue — a session ended, or the reader cleared it.
    public func removeAll() {
        entries.removeAll()
    }
}
