import GitEngine
import StrongholdCore
import SwiftUI

/// The main window for an open repository: a sidebar of workspace sections and refs, and a detail pane.
struct RepositoryView: View {
    @Bindable var repository: RepositoryModel
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView(repository: repository)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                switch repository.section {
                case .changes: ChangesView(workingCopy: repository.workingCopy, headDescription: repository.headDescription)
                case .history: HistoryView(commits: repository.commits)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = repository.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding()
                }
            }
        }
        .navigationTitle(repository.name)
        .navigationSubtitle(subtitle)
        .toolbar {
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
                }
            }
            ForEach(repository.remoteBranches, id: \.remote) { group in
                Section(group.remote) {
                    ForEach(group.branches) { ref in RefRow(ref: ref) }
                }
            }
            if !repository.tags.isEmpty {
                Section("Tags") {
                    ForEach(repository.tags) { ref in RefRow(ref: ref) }
                }
            }
        }
        .listStyle(.sidebar)
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
