import Foundation

/// Something a terminal surface did that is worth recording.
///
/// The vocabulary is shared even though the recording is not. An app with a
/// timeline gets these events; an app without one supplies no recorder and they
/// go nowhere. That split is the point: today a new scrollback event can only
/// exist in the app that happens to own a timeline, because the emission and the
/// transport are the same code. Separated, the emission belongs to the terminal
/// surface and the transport belongs to whoever is storing it.
public struct TerminalTimelineEvent {

    /// The session this happened in, as the host's ledger knows it.
    public let sessionID: Int64

    /// Dotted event name, e.g. `scrollback:entered`.
    public let type: String

    /// Which pane it happened in. Merged into `detail` under `pane` by the
    /// initialiser, because every emitter was adding it by hand and one that
    /// forgot produced an event nothing could attribute.
    public let paneKind: TerminalPaneKind

    /// Where in the app the event came from, for a reader tracing it back.
    public let source: String

    /// Correlates a start with its end so a reader can time the span. Nil for
    /// events that are a moment rather than a span.
    public let durationIdentifier: String?

    /// The event's payload.
    public let detail: [String: Any]

    /// Whether `detail` may carry text of unbounded length — a note body, a
    /// message, anything the user typed.
    ///
    /// Exists because a recorder passing detail as command arguments has a size
    /// ceiling it cannot exceed, and the events that carry note bodies are
    /// exactly the ones that would breach it. The flag says *why* the payload is
    /// unusual rather than naming a transport, so a recorder that has no such
    /// ceiling can ignore it.
    public let detailMayBeLarge: Bool

    public init(
        sessionID: Int64,
        type: String,
        paneKind: TerminalPaneKind,
        source: String,
        durationIdentifier: String? = nil,
        detail: [String: Any] = [:],
        detailMayBeLarge: Bool = false
    ) {
        self.sessionID = sessionID
        self.type = type
        self.paneKind = paneKind
        self.source = source
        self.durationIdentifier = durationIdentifier
        var merged = detail
        merged["pane"] = paneKind.rawValue
        self.detail = merged
        self.detailMayBeLarge = detailMayBeLarge
    }
}

/// Where terminal timeline events go.
///
/// A struct of one closure rather than a protocol, matching the other host-
/// supplied seams here: the host constructs it around whatever it stores events
/// in, and shared code holds it without knowing what that is.
///
/// Optional at every holder, and nil is the whole opt-out — an app with no
/// timeline supplies nothing and every emission becomes a no-op, with the
/// emitting code still present and still correct. Adopting a timeline later is
/// constructing one of these, not adding emission back.
public struct TerminalTimelineRecorder {

    private let handler: (TerminalTimelineEvent) -> Void

    public init(record handler: @escaping (TerminalTimelineEvent) -> Void) {
        self.handler = handler
    }

    public func record(_ event: TerminalTimelineEvent) {
        handler(event)
    }
}

public extension Optional where Wrapped == TerminalTimelineRecorder {

    /// Record an event, building it only if there is somewhere to send it and a
    /// session to attribute it to.
    ///
    /// Both guards live here because every call site had them and each was a
    /// chance to forget one — and the payloads are not free to assemble, so
    /// building an event for a recorder that is nil is work thrown away.
    func record(
        sessionID: Int64?,
        _ event: (Int64) -> TerminalTimelineEvent
    ) {
        guard let self, let sessionID else { return }
        self.record(event(sessionID))
    }
}
