import Foundation

/// Writes this app's text-entry keystrokes into Claude Code's own keybindings
/// file, so the session pane answers to the same keys as the composers.
///
/// This app is not authoritative over the whole file. It owns a set of keys
/// inside the `Chat` context and leaves everything else — other contexts, other
/// keys in `Chat`, `$schema`, `$docs`, unknown fields — exactly as it found
/// them. The file is global and a companion app reads it too, so anything not
/// explicitly ours is somebody else's.
///
/// The read-merge-backup-write shape mirrors what Claude Code's own
/// `/terminal-setup` does to VS Code's keybindings, which is the closest thing
/// to a sanctioned precedent for editing this file from outside.
public enum ClaudeKeybindingsWriter {
    /// Where Claude Code keeps its keybindings.
    ///
    /// Constant. It was settable so a test harness could aim the whole writer
    /// at a temp file and exercise it against real JSON — reading, merging,
    /// unbinding, removing — rather than asserting on a hand-built dictionary
    /// free to disagree with what the file would actually say. That harness
    /// was never written, which left a mutable global deciding where a user's
    /// real keybindings file gets written, read on every automated submission.
    ///
    /// The distinction it was reaching for is still real: the rule about which
    /// submit bytes a pane will act on was wrong for a day, and no assertion
    /// about this type's internals could have caught it, because the question
    /// is what the *file* says. Whoever writes those tests should reintroduce
    /// injection in the shape the tests actually need — a parameter or an
    /// injected path — rather than restoring a settable static.
    public static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/keybindings.json")

    /// The copy taken before every write, alongside whatever `fileURL` names.
    public static var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// The context the user's own keystrokes are written into. Everything else
    /// in the file is left alone — bindings are per-context, and Claude Code
    /// dispatches pickers, permission prompts and dialogs through contexts of
    /// their own.
    public static let context = "Chat"

    /// Each reserved chord, the context it lives in, and what it does there.
    ///
    /// `Chat` only, and deliberately so. Claude Code's completion popup is
    /// cleared with a plain Tab before submitting rather than with a bound
    /// chord — see `SessionSubmit`. Binding anything in `Autocomplete` was
    /// tried and is worse: a bound action *consumes* the key, so the popup
    /// closed and nothing else happened, while an unbound one is swallowed by
    /// the popup entirely. Only Return has accept-then-propagate semantics
    /// there, and binding a key is precisely what suppresses them.
    public static var reservedContexts: [(context: String, binding: Keystroke, action: String)] {
        [("Chat", Keystroke.reservedMachineSubmit, Action.submit.rawValue)]
    }

    public enum Action: String, CaseIterable {
        case submit = "chat:submit"
        case newline = "chat:newline"
    }

    /// Every action string this app claims inside `Chat`.
    public static var ownedActions: Set<String> {
        Set(Action.allCases.map(\.rawValue))
    }

    /// Keys Claude Code already binds to one of these two actions on its own,
    /// and what it binds them to.
    ///
    /// These are the only keys where leaving the file silent is not the same as
    /// turning the key off. Everything else is inert until something binds it,
    /// so it needs no mention; Return submits and Ctrl-J inserts a newline
    /// unless the file explicitly says otherwise. A settings list that omits
    /// one of these has to say so out loud, with a null, or the built-in
    /// binding quietly stays in force and the pane disagrees with the card.
    ///
    /// Reading in the other direction, these are also part of what there is to
    /// adopt: a default the file never mentions is still governing the pane.
    ///
    /// ### This is a model of another program, and nothing checks it
    ///
    /// These two entries are a belief about what Claude Code does when the
    /// keybindings file is silent. They were arrived at by observation, and
    /// there is no interface that would confirm them: the file records
    /// *overrides only*, so a default appears nowhere in it, and the published
    /// schema enumerates the valid actions and contexts without saying which
    /// key starts bound to what. Verified by use as of 2026-08-02.
    ///
    /// **If Claude Code changes them, everything here keeps working and stops
    /// being true.** The whole test suite passes — the tests pin how the file
    /// is read and how the two answers combine, both of which stay correct —
    /// while `plainReturnSubmits` returns the opposite of reality for any user
    /// whose file happens not to mention the key that moved.
    ///
    /// The `enter` entry is the dangerous half. Believing Return submits when
    /// it no longer does means `SessionSubmit.bytes` answers with a carriage
    /// return, and an automated prompt then sits fully typed and uncommitted:
    /// no echo, no error, nothing in a log that names a cause. If that symptom
    /// ever appears, **suspect this constant first** — it is the only input to
    /// that decision which cannot be checked from inside this process.
    ///
    /// The `ctrl+j` entry is milder. Being wrong there writes an unbind for a
    /// key that was not bound, or omits one for a key that is, so the settings
    /// card and the pane disagree about a newline — visible, and recoverable
    /// by the user changing the setting.
    public static let defaultBindings: [String: String] = [
        "enter": Action.submit.rawValue,
        "ctrl+j": Action.newline.rawValue,
    ]

    /// Keys that must be written as an explicit unbind for these settings.
    ///
    /// Kept apart from `ownedBindings` so that function's tuple shape stays
    /// what existing callers already destructure.
    public static func requiredUnbinds(
        for bindings: TextEntryBindings
    ) -> [String] {
        let owned = ownedBindings(for: bindings).map
        return defaultBindings.keys.filter { owned[$0] == nil }.sorted()
    }

    public struct SyncResult {
        /// Binding strings this app wrote, in file order.
        public let written: [String: String]
        /// Keystrokes that reach the composers but have no documented Claude
        /// Code spelling, so the session pane cannot honour them.
        public let unsupported: [Keystroke]
        /// True when the file already said exactly this.
        public let alreadyInSync: Bool
    }

    // MARK: - Building

    /// The bindings this app owns, derived from the settings.
    ///
    /// The reserved machine-submit chord is always present and always maps to
    /// submit. It is not a user preference — every automated prompt this app
    /// sends depends on it, so it has to survive whatever the user chooses.
    public static func ownedBindings(
        for bindings: TextEntryBindings
    ) -> (map: [String: String], unsupported: [Keystroke]) {
        var map: [String: String] = [:]
        var unsupported: [Keystroke] = []

        // Newline first, then submit, so a keystroke in both lists ends up
        // submitting — the same tie-break the in-app matcher makes.
        for keystroke in bindings.newline {
            guard let binding = keystroke.claudeBinding else {
                unsupported.append(keystroke)
                continue
            }
            map[binding] = Action.newline.rawValue
        }
        for keystroke in bindings.submit {
            guard let binding = keystroke.claudeBinding else {
                unsupported.append(keystroke)
                continue
            }
            map[binding] = Action.submit.rawValue
        }

        if let reserved = Keystroke.reservedMachineSubmit.claudeBinding {
            map[reserved] = Action.submit.rawValue
        }
        return (map, unsupported)
    }

    // MARK: - Reading

    /// How the file currently stands relative to a set of settings.
    ///
    /// Deliberately says nothing about *who* wrote the file. Nothing in it
    /// records authorship, so a key this app did not write is indistinguishable
    /// from one it did — naming the companion app as the cause would be a guess
    /// dressed as a fact. What can be stated is the difference itself, which is
    /// also what a reader needs in order to choose a direction.
    public struct FileState {
        public enum Relation {
            /// No file, or nothing in it binds either action.
            case notWritten
            /// The file says exactly what these settings say.
            case matching
            /// The file and these settings disagree.
            case differs
        }

        public let relation: Relation

        /// The settings adopting would produce, or nil when there is nothing
        /// to adopt.
        public let adopted: TextEntryBindings?

        /// Why adopting is refused, or nil when it is allowed. Non-nil only
        /// for a binding the settings model cannot hold at all.
        public let adoptRefusal: String?

        /// Bindings the file carries that these settings do not name.
        public let extra: [String]

        /// Bindings these settings name that the file lacks, or binds to the
        /// other action.
        public let missing: [String]

        /// Keys Claude Code binds on its own that these settings do not name,
        /// and that the file has not turned off.
        ///
        /// Kept apart from `missing` because the two read as opposites. A
        /// missing binding is one the file ought to gain; one of these is a key
        /// that is *already working* in the session pane and should not be —
        /// so describing it as absent tells the reader precisely the wrong
        /// thing about what their session pane is doing.
        public let activeDefaults: [String]

        public var adoptable: Bool { adopted != nil && adoptRefusal == nil }
    }

    /// Compare the file against a set of settings without touching it.
    ///
    /// Reads on every call rather than caching. The file is global, and is
    /// hot-reloaded and editable while this app runs. Far colder than
    /// `SessionSubmit.bytes`, which reads the same file on every automated
    /// submission for the same reason.
    public static func fileState(for bindings: TextEntryBindings) -> FileState {
        let desired = desiredEntries(for: bindings)
        let present = presentEntries()

        // A sequence is a real binding that this settings model cannot hold, so
        // adopting would silently drop it. Refuse rather than lose it.
        let sequences = present.keys.filter { $0.contains(" ") }.sorted()

        let effective = effectiveBindings(given: present)

        var adoptedSubmit: [Keystroke] = []
        var adoptedNewline: [Keystroke] = []
        let reserved = Keystroke.reservedMachineSubmit.claudeBinding
        for (key, action) in effective.sorted(by: { $0.key < $1.key }) {
            // The reserved chord is this app's own infrastructure, never a user
            // choice. Adopting it would put it in the settings card, where it
            // could be deleted — and every automated prompt depends on it.
            guard key != reserved,
                  let keystroke = Keystroke(claudeBinding: key)
            else { continue }
            if action == Action.submit.rawValue {
                adoptedSubmit.append(keystroke)
            } else {
                adoptedNewline.append(keystroke)
            }
        }

        // A key wanted as an explicit unbind, versus one wanted as a binding.
        // Splitting them is what lets the two be described honestly: the first
        // is a default currently in force, the second is a binding not yet
        // written.
        let disagreeing = desired.keys.filter { present[$0] != desired[$0] }
        let wantsUnbind: (String) -> Bool = { key in
            if let value = desired[key] { return value == nil }
            return false
        }

        let relation: FileState.Relation
        if present.isEmpty {
            relation = .notWritten
        } else if present == desired {
            relation = .matching
        } else {
            relation = .differs
        }

        let hasAnything = !adoptedSubmit.isEmpty || !adoptedNewline.isEmpty
        return FileState(
            relation: relation,
            adopted: hasAnything
                ? TextEntryBindings(
                    submit: adoptedSubmit, newline: adoptedNewline)
                : nil,
            adoptRefusal: sequences.isEmpty
                ? nil
                : sequences.joined(separator: ", "),
            extra: present.keys.filter { desired[$0] == nil }.sorted(),
            missing: disagreeing.filter { !wantsUnbind($0) }.sorted(),
            activeDefaults: disagreeing.filter(wantsUnbind).sorted()
        )
    }

    /// What the session pane actually does: Claude Code's own bindings, as
    /// amended by the file.
    ///
    /// The file alone is not the answer to that question. A default the file
    /// never mentions is still governing the pane — Ctrl-J inserting a newline,
    /// say — while an explicit null *removes* a default rather than overriding
    /// it. Anything reasoning about what a keystroke will do there has to start
    /// from the defaults and apply the file over them, in that order.
    static func effectiveBindings(
        given present: [String: String?]
    ) -> [String: String] {
        var effective = defaultBindings
        for (key, action) in present {
            if let action {
                effective[key] = action
            } else {
                effective.removeValue(forKey: key)
            }
        }
        return effective
    }

    /// Whether a bare carriage return commits a prompt in the session pane.
    ///
    /// True when Return's effective binding is submit — because the file says
    /// so, or because the file is silent about Return and Claude Code's own
    /// default applies.
    ///
    /// Read rather than inferred from this app's settings, because the file is
    /// what the pane obeys. If the two have drifted, the file is right and the
    /// settings are a wish.
    ///
    /// Asks for *every* binding, not just this app's. Return bound to any of
    /// the other Chat actions — cancel, undo, external editor, a `command:`
    /// binding — is Return not submitting, exactly as much as if it were bound
    /// to newline. Reading only this app's actions there left Claude Code's
    /// `enter: chat:submit` default apparently in force and answered true,
    /// which sends a carriage return into a key bound to something else.
    public static var plainReturnSubmits: Bool {
        returnSubmits(in: (try? readRoot()) ?? [:])
    }

    /// The same question against a document rather than the file on disk, so
    /// the decision — including which of the two reads it asks for — is
    /// exercisable. Keeping the `ownedOnly: false` choice inside here rather
    /// than at the property is the point: it is the part that was wrong.
    static func returnSubmits(in root: [String: Any]) -> Bool {
        let all = chatEntries(in: root, ownedOnly: false)
        return effectiveBindings(given: all)["enter"] == Action.submit.rawValue
    }

    /// What the file would say if these settings were written to it. A nil
    /// value means the key is explicitly unbound.
    private static func desiredEntries(
        for bindings: TextEntryBindings
    ) -> [String: String?] {
        var entries: [String: String?] = [:]
        for (key, action) in ownedBindings(for: bindings).map {
            entries[key] = action
        }
        for key in requiredUnbinds(for: bindings) {
            entries.updateValue(nil, forKey: key)
        }
        return entries
    }

    /// The Chat block's bindings, as a map with nil for an explicit unbind.
    ///
    /// `ownedOnly` picks which of two different questions is being asked, and
    /// they need different answers:
    ///
    /// - **What did this app write?** Only keys bound to one of its two
    ///   actions, plus explicit unbinds on the keys Claude Code binds by
    ///   default. A binding to somebody else's action is not this app's and
    ///   must not read as ours when comparing the file against settings.
    /// - **What will the pane actually do?** Everything. A key bound to
    ///   another action is *bound*, and the default no longer governs it —
    ///   filtering it out leaves the default in force and reports the opposite
    ///   of the truth.
    ///
    /// Split out from the file read so both can be exercised against a literal
    /// document. Every branch here decides which bytes an automated submission
    /// sends, and getting it wrong has no symptom.
    static func chatEntries(
        in root: [String: Any],
        ownedOnly: Bool
    ) -> [String: String?] {
        let blocks = root["bindings"] as? [[String: Any]] ?? []
        guard
            let block = blocks.first(where: {
                $0["context"] as? String == context
            }),
            let existing = block["bindings"] as? [String: Any]
        else { return [:] }

        let ours = ownedActions
        var entries: [String: String?] = [:]
        for (key, value) in existing {
            if let action = value as? String {
                if !ownedOnly || ours.contains(action) {
                    entries[key] = action
                }
            } else if value is NSNull, defaultBindings.keys.contains(key) {
                entries.updateValue(nil, forKey: key)
            }
        }
        return entries
    }

    /// What the file says now, narrowed to the entries this app claims.
    private static func presentEntries() -> [String: String?] {
        chatEntries(in: (try? readRoot()) ?? [:], ownedOnly: true)
    }

    // MARK: - Writing

    /// Merge this app's bindings into the file, backing up first.
    ///
    /// Returns without writing when the file already matches, so opening
    /// settings does not churn a backup on every visit.
    @discardableResult
    public static func sync(_ bindings: TextEntryBindings) throws -> SyncResult {
        let (owned, unsupported) = ownedBindings(for: bindings)
        var root = try readRoot()
        var changed = false

        // The user's keystrokes go into Chat only. They must never reach
        // Autocomplete, where Return means "accept this completion".
        changed =
            reconcile(
                actions: owned,
                unbinds: requiredUnbinds(for: bindings),
                into: context,
                of: &root
            ) || changed

        // The reserved chord additionally goes wherever an automated prompt
        // might land. `reservedContexts` holds exactly one entry today and it
        // names the same context written above, so this loop currently does
        // nothing — it is the hook for a second context rather than live
        // routing, and `reservedContexts` is where that decision is recorded.
        for entry in reservedContexts where entry.context != context {
            guard let binding = entry.binding.claudeBinding else { continue }
            changed =
                upsert([binding: entry.action],
                       into: entry.context, of: &root) || changed
        }

        guard changed || !FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return SyncResult(
                written: owned, unsupported: unsupported, alreadyInSync: true)
        }

        try backupExisting()
        try writeAtomically(root)
        return SyncResult(
            written: owned, unsupported: unsupported, alreadyInSync: false)
    }

    /// Make sure the file carries the reserved machine-submit binding in every
    /// context an automated prompt can land in, adding it where absent and
    /// leaving everything else alone.
    ///
    /// Called at launch, and deliberately narrower than `sync`: it writes *only*
    /// the reserved chord, never the user's chosen keystrokes. The file is
    /// global, so pushing this app's full binding set on every launch would
    /// stomp whatever the companion app last wrote, for no reason.
    ///
    /// This is what lets automated submission stop reasoning about whether a
    /// sync has happened. The chord is present because this app put it
    /// there, not because the user visited a settings pane.
    @discardableResult
    public static func ensureReservedBinding() throws -> Bool {
        guard !hasReservedBinding else { return false }

        var root = try readRoot()
        var changed = false
        for entry in reservedContexts {
            guard let binding = entry.binding.claudeBinding else { continue }
            changed =
                upsert([binding: entry.action],
                       into: entry.context, of: &root) || changed
        }
        guard changed else { return false }

        try backupExisting()
        try writeAtomically(root)
        return true
    }

    /// Merge this app's keys into a context *and drop the ones it no longer
    /// claims*, creating the block if it is absent.
    ///
    /// The removal is what keeps the file from silting up. Without it, changing
    /// a submit keystroke leaves the previous one bound to submit for good, so
    /// both keep submitting and the file steadily accumulates every keystroke
    /// the user ever chose.
    ///
    /// Only keys mapping to one of the two actions here are eligible for
    /// removal, so every other binding in the context survives untouched. But
    /// within those two actions the sweep cannot be selective: the file records
    /// nothing about which app wrote a key, so removing what these settings do
    /// not name will also remove a key the companion app put there. That is the
    /// intended meaning of writing this file rather than an accident of it —
    /// these settings win outright, and the other app adopts afterwards.
    ///
    /// Returns whether anything actually changed, so callers can skip writing.
    private static func reconcile(
        actions: [String: String],
        unbinds: [String],
        into name: String,
        of root: inout [String: Any]
    ) -> Bool {
        var blocks = root["bindings"] as? [[String: Any]] ?? []
        var index = blocks.firstIndex { $0["context"] as? String == name }
        if index == nil {
            blocks.append(["context": name, "bindings": [String: Any]()])
            index = blocks.count - 1
        }
        guard let index else { return false }

        var block = blocks[index]
        var existing = block["bindings"] as? [String: Any] ?? [:]
        let before = existing

        let ours = ownedActions
        for (key, value) in existing {
            guard let action = value as? String, ours.contains(action),
                  actions[key] == nil
            else { continue }
            existing.removeValue(forKey: key)
        }
        for (key, action) in actions { existing[key] = action }
        for key in unbinds { existing[key] = NSNull() }

        if NSDictionary(dictionary: before).isEqual(to: existing) {
            return false
        }
        block["bindings"] = existing
        blocks[index] = block
        root["bindings"] = blocks
        root["$schema"] =
            root["$schema"]
            ?? "https://www.schemastore.org/claude-code-keybindings.json"
        return true
    }

    /// Merge keys into one context block, creating the block if it is absent.
    /// Returns whether anything actually changed, so callers can skip writing.
    ///
    /// Purely additive, and kept that way for `ensureReservedBinding`: a launch
    /// must be able to restore the reserved chord without touching a single
    /// other key, whoever wrote it.
    private static func upsert(
        _ keys: [String: String],
        into name: String,
        of root: inout [String: Any]
    ) -> Bool {
        var blocks = root["bindings"] as? [[String: Any]] ?? []
        var index = blocks.firstIndex { $0["context"] as? String == name }
        if index == nil {
            blocks.append(["context": name, "bindings": [String: Any]()])
            index = blocks.count - 1
        }
        guard let index else { return false }

        var block = blocks[index]
        var existing = block["bindings"] as? [String: Any] ?? [:]
        let before = existing
        // Only the keys we own are touched; everything else in this context is
        // left exactly as found.
        for (key, action) in keys { existing[key] = action }

        if NSDictionary(dictionary: before).isEqual(to: existing) {
            return false
        }
        block["bindings"] = existing
        blocks[index] = block
        root["bindings"] = blocks
        root["$schema"] =
            root["$schema"]
            ?? "https://www.schemastore.org/claude-code-keybindings.json"
        return true
    }

    /// Whether an automated prompt can rely on the reserved chord, repairing
    /// the file if it exists but has lost it.
    ///
    /// Evaluated per submission rather than cached, so a file edited or deleted
    /// after launch is noticed immediately.
    ///
    /// Repair rather than fall back, because falling back is not actually safe
    /// here: if the chord was removed while `enter` is still bound to
    /// `chat:newline`, a carriage return inserts a newline and the prompt never
    /// sends. The chord is app infrastructure rather than a preference, and the
    /// settings card keeps it hidden for exactly this reason — so restoring it
    /// is repairing damage, not overriding a choice.
    ///
    /// A missing file is different and genuinely does fall back: with no
    /// bindings at all Claude Code is on its `enter: chat:submit` default, so a
    /// carriage return is the only thing that works.
    public static var reservedBindingIsUsable: Bool {
        if hasReservedBinding { return true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        do {
            try ensureReservedBinding()
        } catch {
            GalacticLog.debug(
                "keybindings",
                "the reserved binding is missing and could not be restored "
                    + "(\(error)) — falling back to a carriage return"
            )
            return false
        }
        GalacticLog.debug(
            "keybindings", "restored the reserved machine-submit binding")
        return hasReservedBinding
    }

    /// Whether the file currently carries the reserved machine-submit
    /// binding.
    ///
    /// This is what tells automated submission which bytes to send. It reads
    /// the file rather than trusting a flag because the file is global,
    /// hot-reloaded, and editable by hand or by a companion app — a cached "we
    /// synced once" belief could be false by the time it mattered, and the
    /// failure would be a prompt silently not sending.
    ///
    /// Reads are cheap (a few hundred bytes) and happen once per automated
    /// submission, not per keystroke.
    /// True only when the chord is bound in *every* context an automated
    /// prompt can land in. Present in some but not others is the state that
    /// makes automation work for plain text and fail for slash commands, so it
    /// counts as absent and gets repaired.
    ///
    /// `reservedContexts` names exactly one context today, so in practice this
    /// is a single lookup. The plural is the shape rather than the current
    /// state, and it is what makes adding a second context safe.
    public static var hasReservedBinding: Bool {
        let root = (try? readRoot()) ?? [:]
        let blocks = root["bindings"] as? [[String: Any]] ?? []

        return reservedContexts.allSatisfy { entry in
            guard let binding = entry.binding.claudeBinding else { return true }
            return blocks.contains { block in
                block["context"] as? String == entry.context
                    && (block["bindings"] as? [String: Any])?[binding]
                        as? String == entry.action
            }
        }
    }

    // MARK: - File handling

    private static func readRoot() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        // A file that exists but does not parse is left for the backup to
        // preserve rather than merged into — merging into a guess would be a
        // silent way to lose whatever was actually in there.
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return [:] }
        return root
    }

    private static func backupExisting() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        if manager.fileExists(atPath: backupURL.path) {
            try manager.removeItem(at: backupURL)
        }
        try manager.copyItem(at: fileURL, to: backupURL)
    }

    private static func writeAtomically(_ root: [String: Any]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // .atomic so a crash mid-write cannot leave Claude Code reading a
        // half-file. It hot-reloads this path, so a torn write would be
        // observed, not merely persisted.
        try data.write(to: fileURL, options: .atomic)
    }
}
