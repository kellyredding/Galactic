import Foundation

/// Prompt submission for text a host composed itself — Send to Claude,
/// Review with Claude, /handoff, /compact, /clear, and the prose that
/// re-enters a resumed session.
///
/// None of these are keystrokes the user pressed, so none of them may
/// depend on whichever keystroke the user bound to submit. Routing them
/// through one seam keeps automated submission correct when text-entry
/// settings change, instead of scattering the assumption across every
/// call site.
///
/// What a host still owns is the *signal* that a prompt was taken: that
/// comes from its own agent integration, not from the terminal. See
/// `SubmitVerification`.
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

    /// How long to keep waiting for confirmation that a submit was accepted
    /// before treating it as swallowed.
    ///
    /// This bound has to exceed however long the host's acceptance signal
    /// takes to arrive — a window shorter than the signal it waits on reports
    /// every send as lost. Measured against Claude Code's
    /// UserPromptSubmit hook: ~68ms mid-session, and 299–430ms on resume,
    /// where the child is replaying a conversation when the hook fires and is
    /// slower to dispatch it. A 250ms window sat between those two figures and
    /// retyped a prompt that had already been accepted 35ms later.
    ///
    /// Generous on purpose, because the two directions cost differently. Too
    /// long only delays recovering a genuinely lost prompt, on a path nobody
    /// is waiting on interactively. Too short duplicates a prompt that
    /// worked — and duplicate work is worse than late work.
    public static let submitVerifyTimeout: TimeInterval = 2.0

    /// How often to check for that confirmation within the bound above.
    ///
    /// Polled rather than slept through so a fast acceptance is noticed when it
    /// happens instead of at the deadline: the bound governs when a send is
    /// declared lost, not how long a successful one is watched.
    public static let submitVerifyPollInterval: TimeInterval = 0.05

    /// Maximum resend attempts before giving up. Each costs up to one
    /// `submitVerifyTimeout` plus an `inputPacingDelay`, so a prompt that never
    /// lands is abandoned after roughly six seconds.
    public static let maxSubmitRetries: Int = 2

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

/// How a host recognises that an automated prompt was actually taken.
///
/// Supplied by the host rather than resolved here, because nothing observable
/// from the terminal answers it. Five signals available on this side were
/// measured and every one reported ready against a prompt that did not exist:
/// the keyboard protocol flag (pushed early, never popped), bytes received from
/// the child (its first bytes are terminal setup), screen content under three
/// different anchors (a launcher's banner and a restored screen both satisfy
/// it), silence in the child's output (there is a long quiet gap mid-startup),
/// and the agent's own readiness hook (it fires before the input layer paints).
///
/// What does answer it is the agent reporting receipt in its own words — for
/// Claude Code, the UserPromptSubmit hook. That arrives over a host's event
/// channel, so the host provides it and the mechanism here consumes it.
public struct SubmitVerification {
    /// True once the agent has reported receiving the prompt.
    ///
    /// Must be a genuine report from the agent, not an inference about the
    /// terminal. A predicate that guesses turns this from a safety net into a
    /// prompt duplicator.
    public let isAccepted: () -> Bool

    /// Whether the session is still alive and worth retrying into.
    public let isAlive: () -> Bool

    public init(
        isAccepted: @escaping () -> Bool,
        isAlive: @escaping () -> Bool
    ) {
        self.isAccepted = isAccepted
        self.isAlive = isAlive
    }
}

extension TerminalBackend {
    /// Watch for confirmation that a just-submitted prompt was taken, and
    /// retype it if it was not.
    ///
    /// Verification rather than prediction, because readiness is not observable
    /// from out here — see `SubmitVerification` for the five signals that were
    /// tried and disproved. A prompt lost on this path fails with no echo and
    /// no error, so without a closed loop the only symptom is an agent that
    /// never answers.
    ///
    /// A nil `verification` disables the loop and returns immediately. That is
    /// the supported way for a host to opt out — by passing a value, so the
    /// mechanism stays wired and adopting it later is a value change rather
    /// than a new integration.
    ///
    /// The retry repeats the whole gesture — text, pause, submit — rather than
    /// the submit alone. Resending a bare submit is what made this unsafe to
    /// run on a resumed session: by the time a retry fires the prompt is
    /// usually empty, and Claude Code reads Enter-on-empty as "repeat the last
    /// command", so a retry meant to rescue a lost prompt would re-run whatever
    /// ran before it. Typing first means Enter never arrives against an empty
    /// box.
    ///
    /// It trades that for a narrower hazard: if the text did land and only the
    /// submit was lost, retyping doubles it. Nothing observable distinguishes
    /// those two states — a buffer read shows the statusline and hint rows,
    /// never the input line — so the bound on `submitVerifyTimeout` is what
    /// keeps this safe, not a screen read.
    public func verifySubmission(
        text: String,
        verification: SubmitVerification?,
        retriesLeft: Int = SessionSubmit.maxSubmitRetries
    ) {
        guard let verification else { return }
        awaitAcceptance(
            deadline: Date() + SessionSubmit.submitVerifyTimeout,
            verification: verification
        ) { [weak self] accepted in
            guard let self, verification.isAlive() else { return }

            if accepted {
                SessionSubmit.log("  accepted (\(retriesLeft) retries unused)")
                return
            }
            if retriesLeft <= 0 {
                SessionSubmit.log("  NOT accepted — retries exhausted, giving up")
                return
            }

            SessionSubmit.log(
                "  NOT accepted — retyping and resubmitting (\(retriesLeft) left)"
            )
            self.send(text: text, asPaste: false)

            DispatchQueue.main.asyncAfter(
                deadline: .now() + SessionSubmit.inputPacingDelay
            ) { [weak self] in
                guard let self, verification.isAlive() else { return }
                self.submitPrompt()
                self.verifySubmission(
                    text: text,
                    verification: verification,
                    retriesLeft: retriesLeft - 1
                )
            }
        }
    }

    /// Poll until the host reports the prompt taken, or the deadline passes.
    private func awaitAcceptance(
        deadline: Date,
        verification: SubmitVerification,
        _ completion: @escaping (Bool) -> Void
    ) {
        if verification.isAccepted() {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionSubmit.submitVerifyPollInterval
        ) { [weak self] in
            guard let self, verification.isAlive() else { return }
            self.awaitAcceptance(
                deadline: deadline, verification: verification, completion)
        }
    }

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
        waitForInputReady(
            deadline: Date() + SessionSubmit.kittyReadyTimeout, body)
    }

    /// Poll until the child can decode a CSI-u chord, or the deadline passes.
    ///
    /// Decodability alone, deliberately. This is for the submit keystroke,
    /// which follows text already written through `whenAcceptingInput` — so
    /// something has painted by the time this runs, and re-checking for it
    /// here would be asking a question already answered. Kept separate from
    /// the fuller gate so neither can be widened by accident into the other's
    /// job.
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

    /// Poll until the child can both decode input and has somewhere to put it,
    /// or the deadline passes.
    ///
    /// Three conditions, because no single one of them is honest and each is
    /// wrong in a way the other two are not.
    ///
    /// The keyboard protocol answers whether a chord written as a CSI-u
    /// sequence will be decoded at all — without it the bytes are discarded
    /// rather than misread. It says nothing about timing: a program pushes
    /// those flags early in its startup, and never pops them, so on a reused
    /// terminal the flag is already true before the new child has run.
    ///
    /// Output received answers freshness, and only freshness. It is cleared at
    /// each process start, so it cannot be satisfied by the child that just
    /// died — but a program's first bytes are terminal setup rather than
    /// anything drawn, so it goes true at nearly the same moment the protocol
    /// flag does.
    ///
    /// Visible content answers timing, and only timing. A drawn screen is a
    /// program with an input layer, roughly a sixth of a second after its
    /// first byte. Alone it is the most convincing of the three lies, because
    /// a restarted child inherits a terminal that genuinely does have the
    /// previous lifecycle's output on it.
    ///
    /// Required together, they mean: content is on screen, and a child that is
    /// known to be running put it there, and a chord sent now will be decoded.
    /// That is still not proof an input field is focused — nothing observable
    /// from out here is — but each signal's failure mode is covered by
    /// another's, which none of them manages on its own.
    ///
    /// Polling rather than observing because the engine exposes all three as
    /// state and publishes a change for none, and the wait is bounded.
    private func waitForInputReady(
        deadline: Date, _ completion: @escaping (Bool) -> Void
    ) {
        if isKittyKeyboardActive, hasReceivedOutput, hasVisibleContent {
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
            self.waitForInputReady(deadline: deadline, completion)
        }
    }
}
