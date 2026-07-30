import Foundation
import Galactic

/// Prompt submission for text Galaxy composed itself — Send to Claude,
/// Review with Claude, /handoff, /compact, /clear. Kept in Galaxy (not
/// Galactic) so the gesture needs no engine release: it rides existing
/// public protocol requirements.
///
/// None of these are keystrokes the user pressed, so none of them may
/// depend on whichever keystroke the user bound to submit. Routing them
/// through one seam keeps automated submission correct when text-entry
/// settings change, instead of scattering the assumption across every
/// call site.
public enum SessionSubmit {
    /// Bytes that Claude Code resolves to `chat:submit`.
    ///
    /// Two instruments, and which one works depends on what Return currently
    /// means in the session pane:
    ///
    /// - **Return submits.** A bare carriage return is the whole job. It needs
    ///   no keyboard protocol, no CSI-u decoding, and cannot be misread as
    ///   text.
    /// - **Return does anything else** — inserts a newline, or is unbound.
    ///   Then a carriage return is useless or actively wrong, and the reserved
    ///   chord goes out instead as a kitty functional key: `CSI 13;16u`, where
    ///   16 is 1 + shift 1 + alt 2 + ctrl 4 + super 8.
    ///
    /// Choosing between them is not a preference. Measured behaviour: the chord
    /// is honoured only while Return is bound to something other than submit.
    /// With `enter: chat:submit` in force it is silently ignored, and a prompt
    /// sent that way sits fully typed and uncommitted. The likeliest reason is
    /// that Claude Code services the carriage return directly in that
    /// configuration and never runs the CSI-u parser for Return at all — but
    /// the mechanism is inference, and the rule is observation.
    ///
    /// Which turns out to be no loss whatsoever, because the two conditions are
    /// exact complements: the chord fails in precisely the case where a
    /// carriage return already submits, and works in every case where it does
    /// not. Do not collapse this back to one instrument. A single one cannot
    /// cover both, and each fails silently — no echo, no error, just a prompt
    /// that never sends.
    public static var bytes: [UInt8] {
        // Checked per submission, not cached: the file is global, hot-reloaded,
        // and can be edited or deleted while Galaxy runs. It reads a few
        // hundred bytes, and every caller here is a human-initiated action —
        // do not move this onto a hot path.
        if ClaudeKeybindingsWriter.plainReturnSubmits { return [0x0D] }
        guard ClaudeKeybindingsWriter.reservedBindingIsUsable else {
            return [0x0D]
        }
        return Array("\u{1b}[13;16u".utf8)
    }

    /// How long to leave between two pieces of input so Claude Code's TUI
    /// processes them as separate events.
    ///
    /// Input arriving in a single batch is decoded before Ink re-renders, so
    /// whatever the first piece changed has not taken effect when the second is
    /// dispatched. Calibrated against that behaviour for the text-then-submit
    /// case rather than guessed at.
    public static let inputPacingDelay: TimeInterval = 0.1

    /// How long to wait for the child to enable the kitty keyboard protocol
    /// before giving up on the reserved chord.
    ///
    /// The chord is a CSI-u sequence, decoded only once the protocol is on.
    /// Claude Code enables it during startup, so there is a window after a pane
    /// launches where writing the chord accomplishes nothing at all —
    /// silently, with no echo and no error.
    ///
    /// Measured, not theorised: every observed resume hit `false` here and
    /// became ready ~52ms later. Without the wait those prompts were writing
    /// the chord into a terminal that could not yet decode it.
    public static let kittyReadyTimeout: TimeInterval = 5.0
    public static let kittyPollInterval: TimeInterval = 0.05

    /// Diagnostics for automated submission.
    ///
    /// Kept in place deliberately, and on a standing channel rather than a
    /// transient one. This path is invisible from the outside — the bytes
    /// either land or vanish with no echo and no error — and every theory
    /// formed by reasoning backwards from the pane turned out wrong. These
    /// lines are what finally distinguished "Galaxy sent the wrong thing" from
    /// "Galaxy sent the right thing into a terminal that could not yet decode
    /// it", and later what revealed that one send path skips the readiness
    /// gate: the giveaway was a line that was absent, not one that was wrong.
    ///
    ///     tail -f ~/.claude/galaxy/galaxy.log | grep Galaxy/submit
    public static func log(_ message: String) {
        GalacticLog.submit(message)
    }

    /// Render composed text for a log line: quoted, and short.
    ///
    /// The quoting and the length both matter — a trailing space is invisible at
    /// the end of a log line, and whether it was written is the first thing to
    /// check when a prompt fails to send.
    ///
    /// The truncation matters because the same seam carries slash commands of a
    /// dozen bytes and scrollback sends of thirty thousand. A measured send of
    /// 269 lines would otherwise put all of them in one log line, burying the
    /// diagnostics this channel exists for in the payload they describe.
    /// Newlines are escaped rather than printed for the same reason: one entry,
    /// one line.
    public static func describe(text: String, head: Int = 48) -> String {
        let escaped = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let shown =
            escaped.count > head
            ? escaped.prefix(head) + "…(+\(escaped.count - head))"
            : escaped
        return "\"\(shown)\" len=\(text.count)"
    }

    /// Render bytes readably, so a log line shows an escape sequence rather
    /// than a list of numbers.
    public static func describe(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            switch byte {
            case 0x1b: return "ESC"
            case 0x0d: return "CR"
            case 0x09: return "TAB"
            default:
                let scalar = UnicodeScalar(byte)
                return scalar.isASCII && byte >= 0x20
                    ? String(Character(scalar)) : "\\x\(String(byte, radix: 16))"
            }
        }.joined()
    }
}

extension TerminalBackend {
    /// Submit whatever was last written to this backend.
    ///
    /// Callers that pace their own write-then-submit must keep doing so; this
    /// changes what submitting sends, not when a caller asks for it.
    public func submitPrompt() {
        let t0 = Date()
        let bytes = SessionSubmit.bytes
        SessionSubmit.log(
            "submitPrompt kittyActive=\(isKittyKeyboardActive) "
                + "bytes=\(SessionSubmit.describe(bytes))"
        )

        // The reserved chord is a CSI-u sequence and is only decoded once the
        // child has turned the kitty protocol on. Writing it earlier is not a
        // slow path — it is a lost keystroke.
        //
        // Decodability only, and the distinction matters. A bare carriage
        // return needs no protocol, so it skips this wait — but needing no
        // *decoding* is not the same as needing no *readiness*: a CR written
        // before the child's input layer is up dies exactly like any other
        // byte. Automated prompts are safe on both branches because readiness
        // is established upstream, by `whenAcceptingInput` in
        // `Session.sendCommand`. Do not drop that gate on the belief that this
        // wait already covers it — it does not, and the carriage-return branch
        // is the path where the gap would bite. That branch is also the common
        // one under the shipped defaults, not a rare fallback.
        guard bytes != [0x0D], !isKittyKeyboardActive else {
            send(bytes: bytes)
            SessionSubmit.log("  wrote submit")
            return
        }
        SessionSubmit.log("  waiting for the kitty protocol…")
        waitForKittyKeyboard(deadline: Date() + SessionSubmit.kittyReadyTimeout) {
            [weak self] ready in
            self?.send(bytes: bytes)
            SessionSubmit.log(
                String(
                    format: "  wrote submit — kitty %@ (+%.0fms)",
                    ready ? "ready" : "TIMED OUT",
                    Date().timeIntervalSince(t0) * 1000)
            )
        }
    }

    /// Run `body` once the child looks ready to accept typed input.
    ///
    /// Kitty activation is a *proxy* here, not a cause. There is no direct
    /// signal for "the composer is mounted and reading"; what we can observe is
    /// that Claude Code turns the keyboard protocol on during startup, so the
    /// flag being up means startup has at least got that far. Close enough to
    /// be useful, and not a guarantee — worth remembering if text still goes
    /// missing after this wait reports ready.
    ///
    /// Needed because a pane's readiness event marks the *process* being up,
    /// not its input layer. Text written into that window is lost in silence —
    /// no echo, no error — and a trailing space, being both the last byte and
    /// whitespace, is the first thing to go.
    ///
    /// `ready` is false when the deadline passed. Callers should write anyway:
    /// a late write beats no write, and the log line is what makes the
    /// difference visible after the fact.
    public func whenAcceptingInput(_ body: @escaping (Bool) -> Void) {
        waitForKittyKeyboard(
            deadline: Date() + SessionSubmit.kittyReadyTimeout, body)
    }

    /// Poll until the child enables the kitty protocol, or the deadline passes.
    ///
    /// Polling rather than observing because the engine exposes the flag but
    /// publishes no change for it, and the wait is bounded and short-lived.
    private func waitForKittyKeyboard(
        deadline: Date, _ completion: @escaping (Bool) -> Void
    ) {
        if isKittyKeyboardActive {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionSubmit.kittyPollInterval
        ) { [weak self] in
            guard let self else { return }
            self.waitForKittyKeyboard(deadline: deadline, completion)
        }
    }
}
