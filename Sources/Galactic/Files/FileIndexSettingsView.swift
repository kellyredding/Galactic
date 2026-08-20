import SwiftUI

/// A settings surface for the shared file index.
///
/// Placed by the application, not by this package: it is a stack of cards with
/// no window, no tab chrome and no title of its own, so a host drops it into
/// whichever pane it thinks the index belongs in. Two applications may file it
/// under different headings and still be showing the same index.
public struct FileIndexSettingsView: View {

    @StateObject private var model = FileIndexSettingsModel()
    @State private var newSkip = ""
    @State private var confirmingStop: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            if let status = model.selectedStatus, !status.needingAttention.isEmpty {
                attention(status)
            }
            folders
            skipList
        }
        // The only load. Everything else that changes this surface runs through
        // the model and reloads itself.
        .onAppear { model.load() }
    }

    // MARK: - Summary

    private var summary: some View {
        SettingsCard(title: "File Index") {
            VStack(alignment: .leading, spacing: 8) {
                if model.roots.isEmpty {
                    Text(
                        model.hasLoaded
                            ? "Nothing has been indexed yet."
                            : "Reading the index…"
                    )
                    .foregroundColor(.secondary)
                } else {
                    // Across every tree, because that is what "the index" is.
                    // A per-root figure lives on the row it belongs to.
                    SettingsRow(label: "Indexed") {
                        Text(
                            "\(model.totalEntries.formatted()) files in "
                                + treeCount
                        )
                        .foregroundColor(.secondary)
                    }
                }
                SettingsRow(label: "Location") {
                    Text(abbreviated(model.indexLocation.path))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var treeCount: String {
        model.roots.count == 1
            ? "1 tree" : "\(model.roots.count) trees"
    }

    private var rootSelection: Binding<String> {
        Binding(
            get: { model.selectedRoot ?? "" },
            set: { model.selectedRoot = $0 }
        )
    }

    // MARK: - Needs attention

    /// Shown only when there is something in it, and above the full list,
    /// because a folder reporting a count it can no longer stand behind is the
    /// one thing on this surface worth interrupting someone for.
    private func attention(_ status: FileIndexRootStatus) -> some View {
        SettingsCard(title: "Needs Attention") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(status.needingAttention) { shard in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: shard.state))
                            .foregroundColor(color(for: shard.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shard.displayName)
                            Text(detail(for: shard))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // A refusal may be permanent — macOS declines some
                        // directories however often you ask. Offering the skip
                        // list here is what keeps this section a list of things
                        // worth doing rather than a standing complaint.
                        if !shard.name.isEmpty {
                            Button("Skip") {
                                Task { await model.skip(shard.name) }
                            }
                            .help(
                                "Stop indexing \"\(shard.displayName)\" in every "
                                    + "tree. Adds it to Skipped Folders."
                            )
                        }
                        refreshButton(shard)
                    }
                }
                if status.needingAttention.count > 1 {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Refresh All") {
                            Task { await model.refreshAllNeedingAttention() }
                        }
                        .disabled(!model.working.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Every folder

    private var folders: some View {
        SettingsCard(title: "Indexed Folders") {
            if let status = model.selectedStatus {
                VStack(alignment: .leading, spacing: 8) {
                    rootChooser(status)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(status.shards) { shard in
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: shard.state))
                                    .foregroundColor(color(for: shard.state))
                                    .frame(width: 14)
                                Text(shard.displayName)
                                if shard.isConsentProtected {
                                    Image(systemName: "lock.shield")
                                        .foregroundColor(.secondary)
                                        .help(
                                            "Reading this folder needs your permission"
                                        )
                                }
                                Spacer()
                                Text(walked(shard))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                refreshButton(shard)
                            }
                            .padding(.vertical, 4)
                            if shard.id != status.shards.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    /// Which tree's folders are listed, and the way out of one.
    ///
    /// A tree is not added here — browsing to a folder in the picker is what
    /// adopts it. This is only how you see what that produced, and stop it.
    @ViewBuilder
    private func rootChooser(_ status: FileIndexRootStatus) -> some View {
        HStack {
            if model.roots.count > 1 {
                Picker("", selection: rootSelection) {
                    ForEach(model.roots, id: \.root) { root in
                        Text(abbreviated(root.root)).tag(root.root)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
            } else {
                Text(abbreviated(status.root)).foregroundColor(.secondary)
            }
            Spacer()
            Text("\(status.totalEntries.formatted()) files")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button("Stop Indexing") {
                confirmingStop = status.root
            }
            .help(
                "Remove this tree from the index. Browsing to it again re-adds it."
            )
        }
        .confirmationDialog(
            "Stop indexing \(abbreviated(confirmingStop ?? ""))?",
            isPresented: stopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Indexing", role: .destructive) {
                if let root = confirmingStop { model.stopIndexing(root: root) }
                confirmingStop = nil
            }
            Button("Cancel", role: .cancel) { confirmingStop = nil }
        } message: {
            Text(
                "Its entries leave the picker and its files are reclaimed. "
                    + "Opening a file under it again will index it from scratch."
            )
        }
    }

    private var stopConfirmation: Binding<Bool> {
        Binding(
            get: { confirmingStop != nil },
            set: { if !$0 { confirmingStop = nil } }
        )
    }

    private func refreshButton(_ shard: FileIndexShardStatus) -> some View {
        Button {
            Task { await model.refresh(shard: shard.name) }
        } label: {
            if model.working.contains(shard.name) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.working.contains(shard.name))
        .help("Read this folder again now")
    }

    // MARK: - Skip list

    private var skipList: some View {
        SettingsCard(title: "Skipped Folders") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Directories with these names are never indexed, in every "
                        + "tree, for every app sharing this index."
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.skipped, id: \.self) { name in
                            HStack {
                                Text(name)
                                // The three built-ins that are wrong for a
                                // checkout: a project may hold a real Library.
                                if model.homeOnlySkips.contains(name) {
                                    Text("home only")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Color.secondary.opacity(0.15)
                                        )
                                        .cornerRadius(3)
                                }
                                Spacer()
                                Button {
                                    Task { await model.unskip(name) }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(affectedHelp(name))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)

                Divider()
                HStack {
                    TextField("Folder name to skip", text: $newSkip)
                        .onSubmit { addSkip() }
                    Button("Add", action: addSkip)
                        .disabled(
                            newSkip.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                }
            }
        }
    }

    private func addSkip() {
        let name = newSkip
        newSkip = ""
        Task { await model.skip(name) }
    }

    private func affectedHelp(_ name: String) -> String {
        let affected = model.shardsAffected(byChanging: name)
        if affected.isEmpty {
            return "Stop skipping \"\(name)\". No indexed folder in any tree "
                + "contains one, so nothing needs re-reading."
        }
        return "Stop skipping \"\(name)\". "
            + "\(affected.count) folder(s) will be read again."
    }

    // MARK: - Presentation

    private func icon(for state: FileIndexShardStatus.State) -> String {
        switch state {
        case .indexed: return "checkmark.circle"
        case .incomplete: return "exclamationmark.triangle"
        case .refused: return "hand.raised"
        case .awaitingWalk: return "clock"
        }
    }

    private func color(for state: FileIndexShardStatus.State) -> Color {
        switch state {
        case .indexed: return .secondary
        case .incomplete: return .orange
        case .refused: return .red
        case .awaitingWalk: return .secondary
        }
    }

    private func detail(for shard: FileIndexShardStatus) -> String {
        switch shard.state {
        case .indexed:
            return ""
        case .refused(let code):
            return FileIndexStatusReport.explanation(
                code: code, isConsentProtected: shard.isConsentProtected
            )
        case .incomplete(let count):
            return "\(count) folder(s) inside could not be read"
        case .awaitingWalk:
            return "Not read yet"
        }
    }

    /// A refused shard reports the time of the *attempt*, and its count is
    /// whatever an earlier walk left behind — so saying "indexed" next to it
    /// would be the misleading half of the row.
    private func walked(_ shard: FileIndexShardStatus) -> String {
        guard let walkedAt = shard.walkedAt else { return "never read" }
        let age = Self.ages.localizedString(
            for: walkedAt, relativeTo: Date()
        )
        switch shard.state {
        case .refused: return "tried \(age)"
        default: return "\(shard.entryCount.formatted()) files · \(age)"
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private static let ages: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
