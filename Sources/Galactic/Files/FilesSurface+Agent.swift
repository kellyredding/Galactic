import Foundation

// What an agent may do with an owner's file sets. Every rule is here, so each
// app's command is a pass-through: an agent reads every set, never changes the
// default, only adds tabs, and removes only sets it made that hold no notes.
extension FilesSurface {

    /// Answer one request against the sets of the owner the agent acts for —
    /// named, because the agent asking need not be the one on screen.
    public func perform(
        _ request: FileSetAgentRequest, forOwner ownerID: String
    ) -> FileSetAgentReply {
        // The first write saves the whole group, so a group made empty here
        // would be written over the sets still waiting on disk.
        restoreIfNeeded(ownerID: ownerID)
        let group = self.group(forOwner: ownerID)

        switch request {
        case .list:
            return .read([
                "sets": group.sets.map { agentSummary(of: $0, in: group) }
            ])
        case .view(let name):
            return view(named: name, in: group)
        case .open(let name, let paths):
            return open(paths: paths, intoSetNamed: name, in: group)
        case .show(let name):
            return show(named: name, in: group)
        case .rename(let name, let newName):
            return rename(named: name, to: newName, in: group)
        case .remove(let name):
            return remove(named: name, from: group)
        }
    }

    // MARK: - Reading

    private func view(named name: String, in group: FileSetGroup)
        -> FileSetAgentReply
    {
        guard let set = group.set(named: name) else {
            return .failure(.noSuchSet(name))
        }
        let files: [[String: Any]] = agentTabs(of: set).map { tab in
            [
                "path": tab.path,
                "notes": set.noteCount(forPath: tab.path),
                "selected": tab.id == set.tabs.selectedID,
            ]
        }
        return .read([
            "set": agentSummary(of: set, in: group),
            "root": set.root.path,
            "files": files,
        ])
    }

    private func agentSummary(of set: FileSet, in group: FileSetGroup)
        -> [String: Any]
    {
        [
            "id": set.id,
            "name": set.name,
            "default": set.isDefault,
            "origin": set.origin.rawValue,
            "files": agentTabs(of: set).count,
            "notes": set.totalNoteCount,
            "selected": set.id == group.selectedID,
        ]
    }

    /// Without the search results: a file this surface wrote rather than one
    /// anybody opened, which persistence leaves out for the same reason.
    private func agentTabs(of set: FileSet) -> [FileTab] {
        let results = Self.searchResultsURL(setID: set.id).path
        return set.tabs.tabs.filter { $0.path != results }
    }

    // MARK: - Opening

    private func open(
        paths: [String], intoSetNamed name: String, in group: FileSetGroup
    ) -> FileSetAgentReply {
        let existing = group.set(named: name)
        if existing?.isDefault == true { return .failure(.defaultIsUsers) }

        var refused: [FileSetAgentRefusal] = []
        var candidates: [URL] = []
        var seen: Set<String> = []
        for path in paths {
            if let reason = Self.refusal(forPath: path) {
                refused.append(FileSetAgentRefusal(path: path, reason: reason))
                continue
            }
            let url = URL(fileURLWithPath: path).standardized
            if seen.insert(url.path).inserted { candidates.append(url) }
        }
        guard !candidates.isEmpty else {
            return .failure(.nothingOpened(refused))
        }

        let target: FileSet
        let created: Bool
        if let existing {
            target = existing
            created = false
        } else {
            let root = Self.agentSetRoot(
                for: candidates, defaultRoot: group.defaultSet.root
            )
            switch group.create(name: name, root: root, origin: .agent) {
            case .failure(let problem):
                return .failure(FileSetAgentFailure(problem.message))
            case .success(let made):
                target = made
                created = true
            }
        }

        var opened: [String] = []
        var alreadyOpen: [String] = []
        for url in candidates {
            if target.tabs.tab(forPath: url.path) != nil {
                alreadyOpen.append(url.path)
                continue
            }
            do {
                try target.open(url: url)
                opened.append(url.path)
            } catch {
                refused.append(
                    FileSetAgentRefusal(
                        path: url.path, reason: Self.reason(for: error)
                    )
                )
            }
        }

        let landed = candidates.map(\.path).first {
            opened.contains($0) || alreadyOpen.contains($0)
        }
        guard let landed else {
            // A set made for files that would not open is an empty strip the
            // user never asked for.
            if created { group.remove(id: target.id) }
            return .failure(.nothingOpened(refused))
        }
        target.selectTab(forPath: landed)
        let onScreen = bringForward(target, in: group)

        return .changed(
            Self.openedMessage(
                setName: target.name,
                created: created,
                opened: opened.count,
                alreadyOpen: alreadyOpen.count,
                refused: refused,
                onScreen: onScreen
            ),
            [
                "set": agentSummary(of: target, in: group),
                "created": created,
                "opened": opened,
                "already_open": alreadyOpen,
                "not_opened": refused.map {
                    ["path": $0.path, "reason": $0.reason]
                },
            ]
        )
    }

    /// A path refused before anything is read.
    static func refusal(forPath path: String) -> String? {
        guard path.hasPrefix("/") else { return "not an absolute path" }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: path, isDirectory: &isDirectory
            )
        else { return "no such file" }
        return isDirectory.boolValue ? "a folder, not a file" : nil
    }

    /// Refused rather than handed to another application, as the reader's own
    /// open does: an agent doing that would launch apps nobody asked for.
    static func reason(for error: Error) -> String {
        switch error as? ReaderFile.LoadFailure {
        case .notText?:
            return "not a text file or an image"
        case .tooLarge(let byteSize, let cap)?:
            return "too large to open here (\(megabytes(byteSize)); the limit "
                + "is \(megabytes(cap)))"
        case .unreadable?, nil:
            return "could not be read"
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// The default set's root when every file sits under it, otherwise the
    /// deepest folder holding them all.
    static func agentSetRoot(for files: [URL], defaultRoot: URL) -> URL {
        let root = defaultRoot.standardized.pathComponents
        let folders = files.map {
            $0.deletingLastPathComponent().standardized.pathComponents
        }
        if folders.allSatisfy({ Array($0.prefix(root.count)) == root }) {
            return defaultRoot
        }
        var shared = folders.first ?? []
        for parts in folders.dropFirst() {
            shared = zip(shared, parts).prefix { $0 == $1 }.map { $0.0 }
        }
        return URL(
            fileURLWithPath: shared.isEmpty
                ? "/" : NSString.path(withComponents: shared)
        )
    }

    // MARK: - Changing

    private func show(named name: String, in group: FileSetGroup)
        -> FileSetAgentReply
    {
        guard let set = group.set(named: name) else {
            return .failure(.noSuchSet(name))
        }
        let onScreen = bringForward(set, in: group)
        return .changed(
            onScreen
                ? "“\(set.name)” is on screen."
                : "“\(set.name)” is selected. " + Self.whereItIs(onScreen: false),
            ["set": agentSummary(of: set, in: group)]
        )
    }

    private func rename(
        named name: String, to newName: String, in group: FileSetGroup
    ) -> FileSetAgentReply {
        guard let set = group.set(named: name) else {
            return .failure(.noSuchSet(name))
        }
        guard !set.isDefault else { return .failure(.defaultIsUsers) }
        let before = set.name
        if let problem = group.rename(id: set.id, to: newName) {
            return .failure(FileSetAgentFailure(problem.message))
        }
        persist(group)
        return .changed(
            "Renamed “\(before)” to “\(set.name)”.",
            ["set": agentSummary(of: set, in: group)]
        )
    }

    private func remove(named name: String, from group: FileSetGroup)
        -> FileSetAgentReply
    {
        guard let set = group.set(named: name) else {
            return .failure(.noSuchSet(name))
        }
        guard !set.isDefault else { return .failure(.defaultIsUsers) }
        guard set.origin == .agent else {
            return .failure(.madeByUser(set.name))
        }
        let notes = set.totalNoteCount
        guard notes == 0 else {
            return .failure(.holdsNotes(set.name, count: notes))
        }

        let closed = agentTabs(of: set).count
        // Each panel is about the set on screen, which is about to go.
        if group.ownerID == currentHost.currentOwnerID,
            group.selectedID == set.id
        {
            dismissPanels()
        }
        removeSet(id: set.id, from: group)
        return .changed(
            Self.removedMessage(setName: set.name, closedFiles: closed),
            ["removed": set.name, "closed_files": closed]
        )
    }

    // MARK: - What the agent is told

    static func openedMessage(
        setName: String,
        created: Bool,
        opened: Int,
        alreadyOpen: Int,
        refused: [FileSetAgentRefusal],
        onScreen: Bool
    ) -> String {
        var lead: String
        if opened == 0 {
            lead = "Nothing new to open: \(filesPhrase(alreadyOpen)) "
                + "\(alreadyOpen == 1 ? "was" : "were") already open in "
                + "“\(setName)”."
        } else if created {
            lead = "Made “\(setName)” and opened \(filesPhrase(opened)) in it."
        } else {
            lead = "Opened \(filesPhrase(opened)) in “\(setName)”."
            if alreadyOpen > 0 {
                lead += " \(alreadyOpen) more "
                    + "\(alreadyOpen == 1 ? "was" : "were") already open."
            }
        }
        lead += " " + whereItIs(onScreen: onScreen)
        return ([lead] + refused.map(\.line)).joined(separator: "\n")
    }

    static func removedMessage(setName: String, closedFiles: Int) -> String {
        switch closedFiles {
        case 0:
            return "Removed “\(setName)”; it had no files open."
        case 1:
            return "Removed “\(setName)” and closed the file open in it."
        default:
            return "Removed “\(setName)” and closed the \(closedFiles) files "
                + "open in it."
        }
    }

    private static func whereItIs(onScreen: Bool) -> String {
        onScreen
            ? "It is on screen."
            : "It will be on screen when the user next comes back to it."
    }

    private static func filesPhrase(_ count: Int) -> String {
        "\(count) file\(count == 1 ? "" : "s")"
    }
}
