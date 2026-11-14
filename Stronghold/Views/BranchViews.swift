import GitEngine
import StrongholdCore
import SwiftUI

/// A dialog opened from the branch menus.
enum BranchDialog: Identifiable, Equatable {
    case newBranch(from: String?)
    case rename(String)
    case delete(String)
    case forceDelete(String)
    case deleteRemote(remote: String, branch: String)
    case forcePush

    var id: String {
        switch self {
        case .newBranch(let from): "new-\(from ?? "")"
        case .rename(let name): "rename-\(name)"
        case .delete(let name): "delete-\(name)"
        case .forceDelete(let name): "force-\(name)"
        case .deleteRemote(let remote, let branch): "remote-\(remote)-\(branch)"
        case .forcePush: "forcepush"
        }
    }
}

/// Asks for a name and creates a branch.
struct NewBranchSheet: View {
    let repository: RepositoryModel
    let startPoint: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checkout = true

    private var problem: String? { name.isEmpty ? nil : BranchName.problem(in: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Branch").font(.headline)
            Text(startPoint.map { "Starts at \($0)." } ?? "Starts at the current commit, \(repository.headDescription).")
                .foregroundStyle(.secondary)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("newBranch.name")
                .onSubmit(create)
            if let problem {
                Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Toggle("Switch to the new branch", isOn: $checkout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Branch", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || problem != nil || repository.isPerformingAction)
                    .accessibilityIdentifier("newBranch.create")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard !name.isEmpty, problem == nil else { return }
        Task {
            if await repository.createBranch(name, from: startPoint, checkout: checkout) { dismiss() }
        }
    }
}

/// The toolbar's branch menu: the current branch, and a way to switch or make another.
struct BranchMenu: View {
    let repository: RepositoryModel
    @Binding var dialog: BranchDialog?

    var body: some View {
        Menu {
            Section("Switch to") {
                ForEach(repository.localBranches) { ref in
                    Button {
                        Task { await repository.switchTo(ref) }
                    } label: {
                        if ref.isHead { Label(ref.shortName, systemImage: "checkmark") } else { Text(ref.shortName) }
                    }
                    .disabled(ref.isHead)
                }
            }
            Divider()
            Button("New Branch\u{2026}") { dialog = .newBranch(from: nil) }
        } label: {
            Label(repository.headDescription, systemImage: "arrow.triangle.branch")
        }
        .accessibilityIdentifier("toolbar.branches")
        .help("Switch branch or create a new one")
    }
}

/// Fetch, Pull and Push, with ahead/behind counts on the last two.
struct SyncButtons: View {
    let repository: RepositoryModel
    @Binding var dialog: BranchDialog?

    private var sync: SyncModel { repository.sync }
    private var disabled: Bool { sync.isBusy || !repository.hasRemote }

    var body: some View {
        Button {
            Task { await sync.fetch() }
        } label: {
            Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(disabled)
        .help("Fetch from all remotes")
        .accessibilityIdentifier("toolbar.fetch")

        Menu {
            Button("Pull with Merge") { Task { await sync.pull(strategy: .merge) } }
            Button("Pull with Rebase") { Task { await sync.pull(strategy: .rebase) } }
            Button("Pull (Fast-Forward Only)") { Task { await sync.pull(strategy: .fastForwardOnly) } }
        } label: {
            countLabel("Pull", icon: "arrow.down", count: repository.currentBehind)
        } primaryAction: {
            Task { await sync.pull() }
        }
        .disabled(disabled || !repository.hasUpstream)
        .help(repository.hasUpstream
              ? (repository.currentBehind > 0 ? "Pull \(repository.currentBehind) new commit(s) from the upstream branch" : "Pull from the upstream branch")
              : "This branch has no upstream to pull from")
        .accessibilityIdentifier("toolbar.pull")

        Menu {
            Button("Force Push\u{2026}") { dialog = .forcePush }
        } label: {
            countLabel("Push", icon: "arrow.up", count: repository.currentAhead)
        } primaryAction: {
            Task { await sync.push() }
        }
        .disabled(disabled || !repository.canPush)
        .help(repository.hasUpstream
              ? (repository.currentAhead > 0 ? "Push \(repository.currentAhead) commit(s) to the upstream branch" : "Push to the upstream branch")
              : "Publish this branch to a remote")
        .accessibilityIdentifier("toolbar.push")
    }

    private func countLabel(_ title: String, icon: String, count: Int) -> some View {
        Label {
            Text(count > 0 ? "\(title) \(count)" : title)
        } icon: {
            Image(systemName: icon)
        }
    }
}

/// Live progress, a cancel button and the last result, floating over the detail pane.
struct SyncStatusBar: View {
    let sync: SyncModel

    var body: some View {
        Group {
            if let activity = sync.activity {
                HStack(spacing: 10) {
                    if let progress = activity.progress {
                        ProgressView(value: progress.fraction).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity.text)
                        .lineLimit(1)
                        .monospacedDigit()
                        .accessibilityIdentifier("sync.status")
                    Button("Cancel") { sync.cancel() }
                        .buttonStyle(.link)
                }
            } else if let notice = sync.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sync.notice")
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        if sync.notice == notice { sync.dismissNotice() }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .opacity(sync.activity == nil && sync.notice == nil ? 0 : 1)
        .padding(.bottom, 10)
    }
}

/// The dialogs, confirmations and alerts for branch actions and sync failures.
struct BranchDialogs: ViewModifier {
    let repository: RepositoryModel
    @Binding var dialog: BranchDialog?
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .sheet(item: newBranchBinding) { start in
                NewBranchSheet(repository: repository, startPoint: start.from)
            }
            .alert("Rename Branch", isPresented: flag { if case .rename = $0 { true } else { false } }) {
                TextField("New name", text: $renameText)
                Button("Rename") {
                    if case .rename(let old) = dialog {
                        let new = renameText
                        Task { _ = await repository.renameBranch(old, to: new) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if case .rename(let old) = dialog { Text("Choose a new name for \u{201C}\(old)\u{201D}.") }
            }
            .confirmationDialog(deleteTitle, isPresented: flag { if case .delete = $0 { true } else { false } },
                                titleVisibility: .visible) {
                Button("Delete Branch", role: .destructive) {
                    if case .delete(let name) = dialog {
                        Task {
                            if await repository.deleteBranch(name) == .needsForce { dialog = .forceDelete(name) }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Commits on it that are merged elsewhere stay safe. If it has unmerged commits you\u{2019}ll be asked again.")
            }
            .confirmationDialog("Delete unmerged branch?", isPresented: flag { if case .forceDelete = $0 { true } else { false } },
                                titleVisibility: .visible) {
                Button("Delete Anyway", role: .destructive) {
                    if case .forceDelete(let name) = dialog { Task { _ = await repository.deleteBranch(name, force: true) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if case .forceDelete(let name) = dialog {
                    Text("\u{201C}\(name)\u{201D} has commits that aren\u{2019}t on any other branch. They can only be recovered from the reflog.")
                }
            }
            .confirmationDialog("Delete the remote branch?", isPresented: flag { if case .deleteRemote = $0 { true } else { false } },
                                titleVisibility: .visible) {
                Button("Delete from Server", role: .destructive) {
                    if case .deleteRemote(let remote, let branch) = dialog {
                        Task { await repository.sync.deleteRemoteBranch(remote: remote, branch: branch) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if case .deleteRemote(let remote, let branch) = dialog {
                    Text("This removes \u{201C}\(branch)\u{201D} from \(remote) for everyone who uses it.")
                }
            }
            .confirmationDialog("Force push?", isPresented: flag { if case .forcePush = $0 { true } else { false } },
                                titleVisibility: .visible) {
                Button("Force Push", role: .destructive) { Task { await repository.sync.push(PushOptions(forceWithLease: true)) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces the remote branch with yours. It stops if someone else has pushed since your last fetch.")
            }
            .alert(repository.sync.failure?.title ?? "", isPresented: Binding(
                get: { repository.sync.failure != nil }, set: { if !$0 { repository.sync.dismissFailure() } }
            ), presenting: repository.sync.failure) { failure in
                if let retry = failure.retry {
                    Button(retry == .pullWithAutostash ? "Pull with Autostash" : "Retry") {
                        Task { await repository.sync.retry(retry) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .alert("Branch action failed", isPresented: Binding(
                get: { repository.actionError != nil }, set: { if !$0 { repository.dismissActionError() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(repository.actionError ?? "")
            }
            .onChange(of: dialog) { _, new in
                if case .rename(let name) = new { renameText = name }
            }
    }

    private var deleteTitle: String {
        if case .delete(let name) = dialog { return "Delete branch \u{201C}\(name)\u{201D}?" }
        return "Delete branch?"
    }

    private struct Start: Identifiable { let from: String?; var id: String { from ?? "" } }

    private var newBranchBinding: Binding<Start?> {
        Binding(get: {
            if case .newBranch(let from) = dialog { Start(from: from) } else { nil }
        }, set: { if $0 == nil, case .newBranch = dialog { dialog = nil } })
    }

    /// A binding that is true while the dialog matches, and clears it when dismissed.
    private func flag(_ matches: @escaping (BranchDialog) -> Bool) -> Binding<Bool> {
        Binding(get: { dialog.map(matches) ?? false }, set: { if !$0, let current = dialog, matches(current) { dialog = nil } })
    }
}

extension View {
    func branchDialogs(repository: RepositoryModel, dialog: Binding<BranchDialog?>) -> some View {
        modifier(BranchDialogs(repository: repository, dialog: dialog))
    }
}
