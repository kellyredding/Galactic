import Foundation

/// A review on its way to being kept, and the event that keeps it.
public struct StoredReview {
    public let sessionID: Int64
    public let eventType: String
    public let source: String
    public let detail: [String: Any]

    public init(
        sessionID: Int64,
        eventType: String,
        source: String,
        detail: [String: Any]
    ) {
        self.sessionID = sessionID
        self.eventType = eventType
        self.source = source
        self.detail = detail
    }
}

/// Where a host keeps reviews so its agent reads them back by command. A host
/// with nowhere to keep them supplies none, and reviews are typed in whole.
public struct ReviewStore {
    /// Keeps a review, answering its id, or nil when it was not kept.
    public let store: (StoredReview, @escaping (Int64?) -> Void) -> Void

    /// The command an agent runs to read back the review kept under an id.
    public let readCommand: (Int64) -> String

    public init(
        store: @escaping (StoredReview, @escaping (Int64?) -> Void) -> Void,
        readCommand: @escaping (Int64) -> String
    ) {
        self.store = store
        self.readCommand = readCommand
    }
}

public struct ReviewDestination {
    public let store: ReviewStore
    public let sessionID: Int64
    public let source: String

    public init(store: ReviewStore, sessionID: Int64, source: String) {
        self.store = store
        self.sessionID = sessionID
        self.source = source
    }
}

/// Sends a review as a short prompt pointing at where it was kept, or whole
/// when it cannot be kept. Claude Code silently drops text from the middle of
/// long typed input (3,838 of 9,510 bytes, measured); a pointer is too short to.
public enum ReviewDelivery {

    public enum Kind {
        case scrollback
        case file

        var noun: String {
            switch self {
            case .scrollback: return "scrollback review"
            case .file: return "file review"
            }
        }
    }

    /// Calls `send` exactly once, on the main queue: with a pointer when the
    /// review was kept, otherwise with the review itself.
    public static func deliver(
        message: String,
        noteCount: Int,
        kind: Kind,
        eventType: String,
        detail: [String: Any] = [:],
        destination: ReviewDestination?,
        send: @escaping (String) -> Void
    ) {
        guard let destination, noteCount > 0 else {
            onMain { send(message) }
            return
        }

        // Set here rather than by callers: these are what the read command
        // prints and what the timeline counts.
        var stored = detail
        stored["message"] = message
        stored["note_count"] = noteCount

        let review = StoredReview(
            sessionID: destination.sessionID,
            eventType: eventType,
            source: destination.source,
            detail: stored
        )

        var sent = false
        destination.store.store(review) { id in
            onMain {
                guard !sent else { return }
                sent = true
                guard let id else {
                    send(message)
                    return
                }
                send(
                    pointer(
                        noteCount: noteCount,
                        kind: kind,
                        readCommand: destination.store.readCommand(id)
                    )
                )
            }
        }
    }

    /// Quoting each note before replying keeps the notes on screen: Claude
    /// Code folds a command's output away.
    public static func pointer(
        noteCount: Int,
        kind: Kind,
        readCommand: String
    ) -> String {
        if noteCount == 1 {
            return "I've sent 1 \(kind.noun) note. Read it with "
                + "`\(readCommand)`, then quote the note before you "
                + "respond to it."
        }
        return "I've sent \(noteCount) \(kind.noun) notes. Read them with "
            + "`\(readCommand)`, then quote each note before you "
            + "respond to it."
    }

    public static func cutOffPointer(
        receivedCharacters: Int,
        sentCharacters: Int,
        readCommand: String
    ) -> String {
        "The message I just sent you arrived cut off: only "
            + "\(receivedCharacters) of its \(sentCharacters) characters "
            + "reached you. Read the full text with `\(readCommand)` and work "
            + "from that instead of what you received."
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
