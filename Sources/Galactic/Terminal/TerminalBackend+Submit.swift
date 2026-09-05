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
    /// The lines land wherever the host pointed `GalacticLog.sink`, so the
    /// file to follow is that application's own log rather than a fixed path:
    ///
    ///     tail -f <the host's log> | grep Galaxy/submit
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

/// What to do about a prompt the agent never confirmed receiving.
///
/// Separate from `SubmitVerification` because noticing a lost prompt and
/// retyping one are different decisions with very different costs, and having
/// only one control for both made every caller that feared the retype give up
/// the signal as well. Detecting costs a bounded poll nobody waits on.
/// Retyping costs a second write of the entire payload, and doubles a prompt
/// in the case where the text landed and only the submit was lost — which
/// nothing observable can distinguish from a total loss.
///
/// So the size of the payload decides this, not whether anyone is watching.
/// A slash command is a dozen bytes and worth retyping; a scrollback selection
/// runs to tens of thousands and is not.
///
/// The second thing that decides it is whether the host submits into a harness
/// that might be busy. `submitVerifyTimeout` is calibrated against an idle
/// harness acknowledging promptly; one that queues prompts of its own
/// acknowledges when it dequeues, which is bounded by whatever it is already
/// doing. A host that submits mid-turn will pass the bound routinely on
/// prompts that land perfectly well, so it must not retype on that signal.
/// How a send finished, for a caller that needs to act on it rather than read
/// about it in a log.
///
/// The gesture already knew all of this and told nobody: `then` fires when the
/// writing is over, which is not the same question, and the verdict computed
/// inside `verifySubmission` went to the log and stopped there. That was fine
/// while every caller's answer to "what if it did not land" was a human reading
/// the channel afterwards. A caller holding a queue needs to know whether to
/// retire an entry, and cannot ask a log.
///
/// Four cases rather than a Bool, because the failures are not
/// interchangeable — one of them is not even a failure — and collapsing them
/// at this level would leave every caller to guess which it had.
public enum SubmitOutcome: Equatable {
    /// The agent reported taking the prompt.
    case accepted

    /// The bound passed with no report, after any retries the policy allowed.
    ///
    /// Deliberately not called "lost". A harness that queues prompts of its own
    /// acknowledges one when it dequeues it, which can be far later than a
    /// bound calibrated for an idle agent — measured at 20s against a prompt
    /// that landed perfectly well.
    case unconfirmed

    /// The session went away before the gesture finished.
    case abandoned

    /// No report was ever possible, because the caller supplied no
    /// verification.
    ///
    /// Distinct from `unconfirmed`: nothing failed and nothing was missed. The
    /// caller said in advance that this send bypasses whatever channel would
    /// have reported it — a context-reset command being the standing example —
    /// so waiting or retrying would only ever produce a duplicate.
    case unverifiable
}

public enum SubmitRetryPolicy {
    /// Retype the whole gesture and resubmit, up to the harness's retry
    /// ceiling. For bounded payloads sent into a harness expected to be idle.
    case retype

    /// Report that the bound passed without confirmation, and stop.
    ///
    /// For payloads where a spurious second copy would be worse than a missed
    /// one, and for sends where an unconfirmed prompt is more likely to be
    /// late than lost. Note the report says *unconfirmed*, not *lost* —
    /// nothing here can tell those apart.
    case reportOnly
}

extension TerminalBackend {
    /// Put a command in front of the agent and commit it — the whole automated
    /// send, in the order that makes it land.
    ///
    /// Compose, wait until the agent can read, write, pace, submit, watch for
    /// acceptance. Every step is load-bearing and several are counter-intuitive
    /// enough that a reimplementation gets them wrong: the wait guards the
    /// *write* rather than the submit, because a pane reporting ready means its
    /// process exists and not that its input layer does; the pause between the
    /// two exists because input arriving in one batch is decoded before the
    /// screen re-renders, so the first piece has not taken effect when the
    /// second is dispatched.
    ///
    /// It is one function because it was three, and each copy lost something
    /// different. One paced with a number of its own and never gained the
    /// readiness wait at all, for three months. One pasted its text before
    /// submitting — the single combination that lets the submit be swallowed
    /// into the paste — and never composed the trailing space that closes a
    /// completion popup. One declined verification by not calling for it, so
    /// there was nothing to opt out of. All three were written by someone
    /// reading the original carefully.
    ///
    /// So the shape here is deliberately narrow. There is no flag for pasting,
    /// because anything that submits must type: the two together is the failure
    /// above, and this way it cannot be spelled. Composition happens here, once,
    /// which is also what guarantees a retype re-sends exactly what the first
    /// attempt sent. And `verification` is an argument rather than an option, so
    /// a caller with no acceptance signal says so by passing nothing rather than
    /// by quietly leaving the question out.
    ///
    /// What stays with the caller is policy: whether a report can arrive at all,
    /// whether a lost payload is worth retyping, and what to do afterwards.
    ///
    /// - Parameters:
    ///   - command: Raw text. Composed here; do not pre-compose it.
    ///   - isAlive: Whether the session is still worth writing to. Checked
    ///     before the write and again before the submit, because the gap
    ///     between them is long enough for a process to die in.
    ///   - then: Runs exactly once when the gesture finishes or abandons, on
    ///     either path. A caller serializing sends releases its gate here, so
    ///     skipping it on the abandon path would strand a queue.
    ///   - outcome: Runs exactly once with what became of the prompt, after any
    ///     retries have settled. Later than `then` on the normal path, and that
    ///     gap is the point: `then` says the writing is over, this says whether
    ///     the agent took it. A caller that only needs to release a gate wants
    ///     `then`; a caller deciding whether to keep the message wants this.
    public func deliverPrompt(
        _ command: String,
        harness: AgentHarness,
        isAlive: @escaping () -> Bool,
        verification: SubmitVerification?,
        retry: SubmitRetryPolicy = .retype,
        then: (() -> Void)? = nil,
        outcome: ((SubmitOutcome) -> Void)? = nil
    ) {
        let text = harness.composedCommand(command)
        SessionSubmit.log("  text=\(SessionSubmit.describe(text: text))")

        if !isKittyKeyboardActive {
            SessionSubmit.log("  waiting for input readiness…")
        }
        let t0 = Date()

        // Strongly held across the wait: readiness established for this backend
        // must not be credited to a replacement, and a half-written gesture is
        // worse than one that never started.
        whenAcceptingInput(harness: harness) { ready in
            guard isAlive() else {
                SessionSubmit.log("  session gone before the write")
                then?()
                outcome?(.abandoned)
                return
            }
            // Submitted only once the text is genuinely there. The pacing
            // delay used to start when the write was *handed over*, which for
            // anything past a pty's ~1022 bytes is well before it has landed —
            // so the submit sent the part that had arrived and the rest turned
            // up afterwards, unattached, as a fragment of its own.
            self.send(text: text, asPaste: false) { wrote in
                SessionSubmit.log(
                    String(
                        format: "  input %@ (+%.0fms) — %@",
                        ready ? "ready" : "TIMED OUT",
                        Date().timeIntervalSince(t0) * 1000,
                        wrote ? "wrote text" : "WRITE INCOMPLETE")
                )

                guard wrote else {
                    // Not submitted, deliberately. A fragment submitted reads
                    // as a whole instruction, which is worse than one that
                    // never went — and the retry policy can still resend the
                    // whole thing, which a half-submitted prompt cannot be
                    // rescued into.
                    SessionSubmit.log(
                        "  not submitting a partial write")
                    then?()
                    outcome?(.abandoned)
                    return
                }

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + harness.inputPacingDelay
                ) {
                    guard isAlive() else {
                        SessionSubmit.log("  session gone before the submit")
                        then?()
                        outcome?(.abandoned)
                        return
                    }
                    self.submitPrompt(harness: harness)
                    self.verifySubmission(
                        text: text,
                        harness: harness,
                        verification: verification,
                        retry: retry,
                        outcome: outcome
                    )
                    then?()
                }
            }
        }
    }

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
        harness: AgentHarness,
        verification: SubmitVerification?,
        retry: SubmitRetryPolicy = .retype,
        retriesLeft: Int? = nil,
        outcome: ((SubmitOutcome) -> Void)? = nil
    ) {
        guard let verification else {
            // Nothing to wait for. A caller that supplied no verification has
            // already said no report can arrive for this send, so the honest
            // answer is that it is unverifiable — not that it failed.
            outcome?(.unverifiable)
            return
        }
        let remaining = retriesLeft ?? harness.maxSubmitRetries
        awaitAcceptance(
            deadline: Date() + harness.submitVerifyTimeout,
            harness: harness,
            verification: verification
        ) { [weak self] accepted in
            // The session going away mid-verification is reported rather than
            // dropped. Silence here reads identically to a verification still
            // in progress, and a caller holding the message would wait on a
            // report that is never coming.
            guard let self, verification.isAlive() else {
                outcome?(.abandoned)
                return
            }

            if accepted {
                switch retry {
                case .retype:
                    SessionSubmit.log("  accepted (\(remaining) retries unused)")
                case .reportOnly:
                    // No retries were available to go unused; saying otherwise
                    // reads as a safety net that was standing by.
                    SessionSubmit.log("  accepted")
                }
                outcome?(.accepted)
                return
            }

            // Reported either way. A caller that declines the retype still
            // wants to know the bound passed without confirmation — this
            // channel is the only trace that leaves anywhere.
            //
            // Worded as unconfirmed rather than lost, and the distinction is
            // real: a harness that queues prompts of its own acknowledges one
            // when it picks it up, which can be long after a bound calibrated
            // for an idle harness. Measured at 20s against Claude Code, for a
            // prompt submitted while it was mid-turn — and that prompt did
            // land. Calling that "NOT accepted" trains a reader to discount
            // the one line that is supposed to mean something.
            guard case .retype = retry else {
                SessionSubmit.log(
                    String(
                        format:
                            "  unconfirmed after %.1fs — not retyped "
                            + "(may still be accepted later)",
                        harness.submitVerifyTimeout)
                )
                outcome?(.unconfirmed)
                return
            }
            if remaining <= 0 {
                SessionSubmit.log("  NOT accepted — retries exhausted, giving up")
                outcome?(.unconfirmed)
                return
            }

            // Retyping is the expensive half, and only some harnesses need
            // it. The reason Claude Code does is that its composer is usually
            // empty by now and a bare submit against an empty composer
            // repeats the previous command — so the second write is what
            // stops a rescue from re-running unrelated work. A harness that
            // does nothing on an empty submit is safe to resubmit directly.
            let resubmit = { [weak self] in
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + harness.inputPacingDelay
                ) {
                    guard let self, verification.isAlive() else {
                        outcome?(.abandoned)
                        return
                    }
                    self.submitPrompt(harness: harness)
                    self.verifySubmission(
                        text: text,
                        harness: harness,
                        verification: verification,
                        retry: retry,
                        retriesLeft: remaining - 1,
                        outcome: outcome
                    )
                }
            }

            if harness.retypeOnRetry {
                SessionSubmit.log(
                    "  NOT accepted — retyping and resubmitting (\(remaining) left)"
                )
                // Waits for the retype the same way the first attempt waits
                // for its own write, and for a sharper reason: this is the
                // rescue. Submitting a half-written retype turns one prompt
                // that went unconfirmed into a fragment that reads as an
                // instruction, which is the outcome a retry exists to avoid.
                self.send(text: text, asPaste: false) { wrote in
                    guard wrote else {
                        SessionSubmit.log(
                            "  retype INCOMPLETE — not resubmitting"
                        )
                        outcome?(.abandoned)
                        return
                    }
                    resubmit()
                }
            } else {
                SessionSubmit.log(
                    "  NOT accepted — resubmitting (\(remaining) left)"
                )
                resubmit()
            }
        }
    }

    /// Poll until the host reports the prompt taken, or the deadline passes.
    private func awaitAcceptance(
        deadline: Date,
        harness: AgentHarness,
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
            deadline: .now() + harness.submitVerifyPollInterval
        ) { [weak self] in
            // A session that dies mid-poll, or a backend that goes away under
            // one, completes rather than stopping where it stands. Abandoning
            // the loop silently is indistinguishable from a poll still running,
            // and the caller decides what an unfinished verification means —
            // this only has to stop pretending one is still in flight.
            guard let self, verification.isAlive() else {
                completion(false)
                return
            }
            self.awaitAcceptance(
                deadline: deadline, harness: harness,
                verification: verification, completion)
        }
    }

    /// Submit whatever was last written to this backend.
    ///
    /// Callers that pace their own write-then-submit must keep doing so; this
    /// changes what submitting sends, not when a caller asks for it.
    public func submitPrompt(harness: AgentHarness) {
        let t0 = Date()
        let bytes = harness.submitBytes
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
        waitForKittyKeyboard(
            deadline: Date() + harness.inputReadinessTimeout, harness: harness
        ) {
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
    public func whenAcceptingInput(
        harness: AgentHarness, _ body: @escaping (Bool) -> Void
    ) {
        waitForInputReady(
            deadline: Date() + harness.inputReadinessTimeout,
            harness: harness, body)
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
        deadline: Date, harness: AgentHarness,
        _ completion: @escaping (Bool) -> Void
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
            deadline: .now() + harness.readinessPollInterval
        ) { [weak self] in
            guard let self else { return }
            self.waitForKittyKeyboard(
                deadline: deadline, harness: harness, completion)
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
        deadline: Date, harness: AgentHarness,
        _ completion: @escaping (Bool) -> Void
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
            deadline: .now() + harness.readinessPollInterval
        ) { [weak self] in
            guard let self else { return }
            self.waitForInputReady(
                deadline: deadline, harness: harness, completion)
        }
    }
}
