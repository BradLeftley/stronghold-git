import GitEngine
import StrongholdCore
import SwiftUI

/// The everyday screen: changed files and the commit box on the left, the diff on the right.
struct ChangesView: View {
    @Bindable var workingCopy: WorkingCopyModel
    let headDescription: String
    @State private var pendingDiscard: DiscardRequest?

    var body: some View {
        Group {
            if workingCopy.status.isClean && !workingCopy.amend && workingCopy.lastCommit == nil {
                ContentUnavailableView("No Changes", systemImage: "checkmark.seal",
                                       description: Text("The working copy matches \(headDescription)."))
                    .accessibilityIdentifier("changes.clean")
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        ChangeListView(workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                        Divider()
                        CommitBox(workingCopy: workingCopy)
                    }
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 520)
                    DiffPane(workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                        .frame(minWidth: 380)
                }
            }
        }
        .confirmationDialog(pendingDiscard?.title ?? "", isPresented: Binding(
            get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }
        ), titleVisibility: .visible, presenting: pendingDiscard) { request in
            Button(request.confirmLabel, role: .destructive) {
                Task { await request.perform(on: workingCopy) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert("Git Error", isPresented: Binding(get: { workingCopy.errorMessage != nil },
                                                 set: { if !$0 { workingCopy.dismissError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workingCopy.errorMessage ?? "")
        }
    }
}

/// A destructive action waiting for the user's confirmation. Discards can't be undone.
enum DiscardRequest: Identifiable {
    case files(Set<String>, untrackedCount: Int)
    case everything(count: Int)
    case hunk(Int)
    case lines(Int)

    var id: String {
        switch self {
        case .files(let paths, _): "files:" + paths.sorted().joined(separator: "|")
        case .everything: "all"
        case .hunk(let index): "hunk:\(index)"
        case .lines(let count): "lines:\(count)"
        }
    }

    var title: String {
        switch self {
        case .files(let paths, _): paths.count == 1 ? "Discard changes to “\((paths.first! as NSString).lastPathComponent)”?" : "Discard changes to \(paths.count) files?"
        case .everything(let count): "Discard all changes to \(count) files?"
        case .hunk: "Discard this hunk?"
        case .lines(let count): count == 1 ? "Discard the selected line?" : "Discard \(count) selected lines?"
        }
    }

    var message: String {
        switch self {
        case .files(_, let untracked) where untracked > 0:
            "Edits are lost for good, and untracked files are deleted. This can’t be undone."
        case .everything:
            "Unstaged edits are lost for good and untracked files are deleted. Staged changes are kept. This can’t be undone."
        default:
            "The changes are removed from the file and can’t be brought back."
        }
    }

    var confirmLabel: String { "Discard" }

    @MainActor
    func perform(on workingCopy: WorkingCopyModel) async {
        switch self {
        case .files(let paths, _): await workingCopy.discard(paths: paths)
        case .everything: await workingCopy.discardAll()
        case .hunk(let index): await workingCopy.discardHunk(index)
        case .lines: await workingCopy.discardSelectedLines()
        }
    }
}

// MARK: - File list

private struct ChangeListView: View {
    @Bindable var workingCopy: WorkingCopyModel
    @Binding var pendingDiscard: DiscardRequest?

    var body: some View {
        List(selection: Binding(get: { workingCopy.selection },
                                set: { new in Task { await workingCopy.select(new) } })) {
            if !workingCopy.conflicted.isEmpty {
                Section("Conflicts") {
                    ForEach(workingCopy.conflicted) { entry in
                        FileRow(entry: entry, area: .conflicted, workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                    }
                }
            }
            Section {
                ForEach(workingCopy.staged) { entry in
                    FileRow(entry: entry, area: .staged, workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                }
            } header: {
                SectionHeader(title: "Staged", count: workingCopy.staged.count,
                              actionTitle: "Unstage All", actionID: "changes.unstageAll") {
                    Task { await workingCopy.unstageAll() }
                }
            }
            Section {
                ForEach(workingCopy.unstaged) { entry in
                    FileRow(entry: entry, area: .unstaged, workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                }
            } header: {
                SectionHeader(title: "Unstaged", count: workingCopy.unstaged.count,
                              actionTitle: "Stage All", actionID: "changes.stageAll") {
                    Task { await workingCopy.stageAll() }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("changes.list")
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let actionTitle: String
    let actionID: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if count > 0 {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier(actionID)
            }
        }
    }
}

private struct FileRow: View {
    let entry: StatusEntry
    let area: ChangeArea
    let workingCopy: WorkingCopyModel
    @Binding var pendingDiscard: DiscardRequest?
    @Environment(\.showFileHistory) private var showFileHistory

    private var selection: FileSelection { FileSelection(path: entry.path, area: area) }
    private var badge: ChangeBadge {
        switch area {
        case .conflicted: .conflicted
        case .staged: entry.stagedBadge ?? .modified
        case .unstaged: entry.unstagedBadge ?? .modified
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            BadgeView(badge: badge)
            VStack(alignment: .leading, spacing: 1) {
                Text((entry.path as NSString).lastPathComponent).lineLimit(1)
                let folder = (entry.path as NSString).deletingLastPathComponent
                if area == .staged, let from = entry.originalPath {
                    Text("from \(from)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } else if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            switch area {
            case .staged:
                Button { Task { await workingCopy.unstage([entry]) } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Unstage")
                .accessibilityLabel("Unstage \(entry.path)")
                .accessibilityIdentifier("unstage.\(entry.path)")
            case .unstaged:
                Button { Task { await workingCopy.stage([entry.path]) } } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stage")
                .accessibilityLabel("Stage \(entry.path)")
                .accessibilityIdentifier("stage.\(entry.path)")
            case .conflicted:
                EmptyView()
            }
        }
        .tag(selection)
        .contextMenu { menu }
    }

    /// The rows the context menu acts on: every selected row if this one is among them, else just this one.
    private func targets() -> Set<FileSelection> {
        workingCopy.selection.contains(selection) ? workingCopy.selection : [selection]
    }

    @ViewBuilder private var menu: some View {
        let chosen = targets()
        switch area {
        case .unstaged:
            Button("Stage") { Task { await workingCopy.stage(chosen) } }
            Button("Discard Changes…", role: .destructive) {
                let paths = Set(chosen.filter { $0.area == .unstaged }.map(\.path))
                let untracked = workingCopy.unstaged.filter { paths.contains($0.path) && $0.kind == .untracked }.count
                pendingDiscard = .files(paths, untrackedCount: untracked)
            }
        case .staged:
            Button("Unstage") { Task { await workingCopy.unstage(chosen) } }
        case .conflicted:
            EmptyView()
        }
        Divider()
        Button("Show File History") { showFileHistory(entry.path) }
            .disabled(entry.kind == .untracked)
        Button("Reveal in Finder") {
            let urls = chosen.map { workingCopy.repository.rootURL.appendingPathComponent($0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chosen.map(\.path).sorted().joined(separator: "\n"), forType: .string)
        }
    }
}

struct BadgeView: View {
    let badge: ChangeBadge

    var body: some View {
        Text(badge.rawValue)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: .rect(cornerRadius: 4))
            .help(badge.label)
            .accessibilityLabel(badge.label)
    }

    private var color: Color {
        switch badge {
        case .added, .untracked: .green
        case .deleted: .red
        case .conflicted: .orange
        case .renamed, .copied: .blue
        default: .gray
        }
    }
}

// MARK: - Commit box

private struct CommitBox: View {
    @Bindable var workingCopy: WorkingCopyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $workingCopy.commitMessage)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                    .accessibilityIdentifier("commit.message")
                if workingCopy.commitMessage.isEmpty {
                    Text(workingCopy.amend ? "Message" : "Commit message")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 84)

            HStack {
                Toggle("Amend", isOn: Binding(get: { workingCopy.amend },
                                              set: { on in Task { await workingCopy.setAmend(on) } }))
                    .toggleStyle(.checkbox)
                    .help("Replace the last commit instead of adding a new one")
                    .accessibilityIdentifier("commit.amend")
                Spacer()
                if summaryLength > 72 {
                    Text("\(summaryLength)/72")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                        .help("The first line is long. 72 characters or fewer reads best.")
                }
                Button(commitTitle) { Task { await workingCopy.commit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workingCopy.canCommit)
                    .accessibilityIdentifier("commit.button")
            }
            if let commit = workingCopy.lastCommit {
                Label("\(commit.id.prefix(7)) \(commit.summary)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("commit.last")
            }
        }
        .padding(10)
    }

    private var summaryLength: Int {
        workingCopy.commitMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first?.count ?? 0
    }

    private var commitTitle: String {
        let count = workingCopy.staged.count
        if workingCopy.amend { return count == 0 ? "Amend" : "Amend with \(count) \(count == 1 ? "File" : "Files")" }
        return count == 0 ? "Commit" : "Commit \(count) \(count == 1 ? "File" : "Files")"
    }
}
