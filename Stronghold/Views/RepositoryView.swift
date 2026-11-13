import GitEngine
import StrongholdCore
import SwiftUI

/// The main window for an open repository: a sidebar of workspace sections and refs, and a detail pane.
struct RepositoryView: View {
    @Bindable var repository: RepositoryModel
    @Environment(AppModel.self) private var app
    @State private var dialog: BranchDialog?

    var body: some View {
        NavigationSplitView {
            SidebarView(repository: repository, dialog: $dialog)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                switch repository.section {
                case .changes: ChangesView(workingCopy: repository.workingCopy, headDescription: repository.headDescription)
                case .history: HistoryView(commits: repository.commits)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let error = repository.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .padding(10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
                    if let notice = repository.actionNotice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .padding(10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                            .onTapGesture { repository.dismissActionNotice() }
                    }
                    SyncStatusBar(sync: repository.sync)
                }
                .padding()
            }
        }
        .navigationTitle(repository.name)
        .navigationSubtitle(subtitle)
        .branchDialogs(repository: repository, dialog: $dialog)
        #if DEBUG
        .onAppear {
            // Screenshots only: open the new-branch sheet.
            if ProcessInfo.processInfo.environment["STRONGHOLD_SHOW_NEW_BRANCH"] == "1" { dialog = .newBranch(from: nil) }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BranchMenu(repository: repository, dialog: $dialog)
            }
            ToolbarItemGroup {
                SyncButtons(repository: repository, dialog: $dialog)
            }
            ToolbarItem {
                Menu {
                    ForEach(app.library.sorted.prefix(20)) { entry in
                        Button(entry.name) { Task { await app.open(entry) } }
                            .disabled(entry.path == repository.repository.rootURL.path)
                    }
                    Divider()
                    Button("Clone Repository…") { app.isShowingCloneSheet = true }
                    Button("Show All Repositories") { app.close() }
                } label: {
                    Label("Repositories", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("toolbar.repositories")
            }
            ToolbarItem {
                Button {
                    Task { await repository.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(repository.isLoading)
            }
            ToolbarItem {
                Button {
                    app.close()
                } label: {
                    Label("Close Repository", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var subtitle: String {
        [repository.headDescription, repository.trackingDescription].compactMap { $0 }.joined(separator: " · ")
    }
}

struct SidebarView: View {
    @Bindable var repository: RepositoryModel
    @Binding var dialog: BranchDialog?

    var body: some View {
        List(selection: Binding(get: { repository.section }, set: { if let s = $0 { repository.section = s } })) {
            Section("Workspace") {
                Label("Changes", systemImage: "square.and.pencil")
                    .badge(repository.status.entries.filter { $0.kind != .ignored }.count)
                    .tag(RepositoryModel.Section.changes)
                    .accessibilityIdentifier("sidebar.changes")
                Label("History", systemImage: "clock")
                    .tag(RepositoryModel.Section.history)
                    .accessibilityIdentifier("sidebar.history")
            }
            Section("Branches") {
                ForEach(repository.localBranches) { ref in
                    RefRow(ref: ref)
                        .contextMenu { localBranchMenu(ref) }
                        .accessibilityIdentifier("branch.\(ref.shortName)")
                }
            }
            ForEach(repository.remoteBranches, id: \.remote) { group in
                Section(group.remote) {
                    ForEach(group.branches) { ref in
                        RefRow(ref: ref)
                            .contextMenu { remoteBranchMenu(ref, remote: group.remote) }
                    }
                }
            }
            if !repository.tags.isEmpty {
                Section("Tags") {
                    ForEach(repository.tags) { ref in
                        RefRow(ref: ref)
                            .contextMenu {
                                Button("Check Out (Detached)") { Task { await repository.switchTo(ref) } }
                                Button("New Branch from Here\u{2026}") { dialog = .newBranch(from: ref.shortName) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func localBranchMenu(_ ref: Ref) -> some View {
        Button("Switch to \(ref.shortName)") { Task { await repository.switchTo(ref) } }
            .disabled(ref.isHead)
        Button("New Branch from Here\u{2026}") { dialog = .newBranch(from: ref.shortName) }
        Divider()
        Button("Rename\u{2026}") { dialog = .rename(ref.shortName) }
        Menu("Track") {
            ForEach(repository.upstreamCandidates, id: \.self) { upstream in
                Button(upstream) { Task { await repository.setUpstream(of: ref.shortName, to: upstream) } }
            }
            if ref.upstream != nil {
                Divider()
                Button("Stop Tracking") { Task { await repository.setUpstream(of: ref.shortName, to: nil) } }
            }
        }
        .disabled(repository.upstreamCandidates.isEmpty && ref.upstream == nil)
        Divider()
        Button("Delete\u{2026}", role: .destructive) { dialog = .delete(ref.shortName) }
            .disabled(ref.isHead)
    }

    @ViewBuilder
    private func remoteBranchMenu(_ ref: Ref, remote: String) -> some View {
        Button("Check Out as Local Branch") { Task { await repository.switchTo(ref) } }
        Button("New Branch from Here\u{2026}") { dialog = .newBranch(from: ref.shortName) }
        Divider()
        Button("Delete from Server\u{2026}", role: .destructive) {
            let prefix = remote + "/"
            let branch = ref.shortName.hasPrefix(prefix) ? String(ref.shortName.dropFirst(prefix.count)) : ref.shortName
            dialog = .deleteRemote(remote: remote, branch: branch)
        }
    }
}

private struct RefRow: View {
    let ref: Ref

    var body: some View {
        HStack {
            Label(ref.shortName, systemImage: icon)
                .fontWeight(ref.isHead ? .semibold : .regular)
            Spacer()
            if ref.ahead > 0 { Text("↑\(ref.ahead)").foregroundStyle(.secondary).monospacedDigit() }
            if ref.behind > 0 { Text("↓\(ref.behind)").foregroundStyle(.secondary).monospacedDigit() }
        }
        .selectionDisabled()
        .help(ref.name)
    }

    private var icon: String {
        switch ref.kind {
        case .tag: "tag"
        case .remoteBranch: "network"
        default: ref.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch"
        }
    }
}
