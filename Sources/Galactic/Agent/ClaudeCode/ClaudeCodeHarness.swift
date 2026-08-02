import Foundation

/// Claude Code, as an `AgentHarness`.
///
/// Every answer here delegates to the implementations that already carry the
/// reasoning — `SessionSubmit` for the wire behaviour, `ClaudeKeybindingsWriter`
/// for configuration. This type adds no knowledge; it exists so that everything
/// vendor-specific is reachable through one role-named door.
public struct ClaudeCodeHarness: AgentHarness {
    public init() {}

    public var submitBytes: [UInt8] { SessionSubmit.bytes }

    public var inputPacingDelay: TimeInterval { SessionSubmit.inputPacingDelay }

    public var inputReadinessTimeout: TimeInterval {
        SessionSubmit.kittyReadyTimeout
    }

    public var readinessPollInterval: TimeInterval {
        SessionSubmit.kittyPollInterval
    }

    public var submitVerifyTimeout: TimeInterval {
        SessionSubmit.submitVerifyTimeout
    }

    public var submitVerifyPollInterval: TimeInterval {
        SessionSubmit.submitVerifyPollInterval
    }

    public var maxSubmitRetries: Int { SessionSubmit.maxSubmitRetries }

    /// Enter on an empty composer repeats the last command, so a bare
    /// resubmit would re-run whatever preceded the lost prompt.
    public var retypeOnRetry: Bool { true }

    /// Both are intercepted at the TUI level before the prompt-submit
    /// pipeline runs, so `UserPromptSubmit` never fires for them.
    public var acceptanceBypassingCommands: Set<String> {
        ["/clear", "/compact"]
    }

    /// A trailing space closes the completion popup that any slash command
    /// opens: the popup filters on the token under the cursor, and a space ends
    /// that token so nothing matches.
    ///
    /// Applied to every command rather than only to those starting with a
    /// slash. A trailing space is inert in the composer either way, and a rule
    /// that inspects the text would have to be kept in step with whatever
    /// Claude Code decides opens a popup next.
    public func composedCommand(_ command: String) -> String {
        command + " "
    }

    public func keystrokeConfigurationState(
        for bindings: TextEntryBindings
    ) -> KeystrokeConfigurationState {
        switch ClaudeKeybindingsWriter.fileState(for: bindings).relation {
        case .matching: return .matching
        case .differs: return .differs
        case .notWritten: return .unconfigured
        }
    }
}
