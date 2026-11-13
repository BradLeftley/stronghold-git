import GitEngine
import StrongholdCore
import SwiftUI

/// The history screen: the commit graph on top, and the selected commit's details, files and diff or
/// blame below. Search filters by message, author, file or content.
struct HistoryView: View {
    @Bindable var history: HistoryModel
    let appeared: () async -> Void
    @State private var searchText = Self.debugValue("STRONGHOLD_HISTORY_SEARCH") ?? ""
    @State private var searchField = Self.debugValue("STRONGHOLD_HISTORY_SEARCH_FIELD").flatMap(HistoryModel.SearchField.init(rawValue:)) ?? .message

    /// Debug builds start with a search from the environment, for screenshots and UI tests.
    private static func debugValue(_ name: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    private struct SearchKey: Equatable {
        var text: String
        var field: HistoryModel.SearchField
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HistoryHeader(history: history, searchField: $searchField)
                Divider()
                list
            }
            .frame(minHeight: 160, idealHeight: 340)
            CommitDetailView(history: history)
                .frame(minHeight: 220, idealHeight: 360)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text(searchField.prompt))
        .task(id: SearchKey(text: searchText, field: searchField)) {
            // Wait for typing to pause before asking git.
            if !searchText.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await history.search(searchText, in: searchField)
        }
        .task { await appeared() }
    }

    @ViewBuilder private var list: some View {
        if history.rows.isEmpty && history.hasLoaded && !history.isLoading {
            if history.isSearching {
                ContentUnavailableView.search(text: history.searchText)
            } else {
                ContentUnavailableView("No Commits Yet", systemImage: "clock",
                                       description: Text("Commits appear here once you make the first one."))
            }
        } else {
            CommitTableView(rows: history.rows, graph: history.graph, selectedID: history.selectedCommit?.id,
                            select: { id in Task { await history.select(id) } },
                            loadMore: { Task { await history.loadMore() } })
        }
    }
}

private struct HistoryHeader: View {
    @Bindable var history: HistoryModel
    @Binding var searchField: HistoryModel.SearchField

    var body: some View {
        HStack(spacing: 10) {
            if let path = history.filePath {
                Label {
                    Text(path).lineLimit(1).truncationMode(.head)
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .font(.callout.weight(.medium))
                Button {
                    Task { await history.clearFileHistory() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Show the full history again")
                .accessibilityLabel("Close file history")
                .accessibilityIdentifier("history.closeFileHistory")
            } else {
                Picker("Show", selection: Binding(get: { history.scope }, set: { scope in
                    Task { await history.setScope(scope) }
                })) {
                    ForEach(HistoryModel.Scope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(history.isSearching)
                .accessibilityIdentifier("history.scope")
            }
            Text(history.listDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("history.description")
            Spacer()
            if history.isLoading { ProgressView().controlSize(.small) }
            if history.filePath == nil {
                Picker("Search in", selection: $searchField) {
                    ForEach(HistoryModel.SearchField.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("What the search field matches")
                .accessibilityIdentifier("history.searchField")
            }
            if let error = history.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Commit details

private struct CommitDetailView: View {
    @Bindable var history: HistoryModel
    @Environment(\.showFileHistory) private var showFileHistory

    var body: some View {
        if let commit = history.selectedCommit {
            HSplitView {
                VStack(spacing: 0) {
                    CommitInfoView(commit: commit, select: { id in Task { await history.select(id) } })
                    Divider()
                    fileList
                }
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
                FileContentPane(history: history)
                    .frame(minWidth: 360)
            }
        } else {
            ContentUnavailableView("Select a Commit", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Pick a commit to see what changed."))
        }
    }

    private var fileList: some View {
        List(selection: Binding(get: { history.selectedFile }, set: { file in
            Task { await history.selectFile(file) }
        })) {
            Section(history.isLoadingFiles ? "Loading files…" : fileCountText) {
                ForEach(history.changedFiles) { file in
                    HStack(spacing: 8) {
                        BadgeView(badge: file.badge)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent).lineLimit(1)
                            if let old = file.oldPath {
                                Text("from \(old)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            } else {
                                let folder = (file.path as NSString).deletingLastPathComponent
                                if !folder.isEmpty {
                                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            }
                        }
                    }
                    .tag(file)
                    .contextMenu {
                        Button("Show File History") { showFileHistory(file.path) }
                        Button("Blame") {
                            Task {
                                await history.selectFile(file)
                                await history.setFileView(.blame)
                            }
                        }
                        .disabled(file.change == .deleted)
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        }
                    }
                    .accessibilityIdentifier("history.file.\(file.path)")
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("history.files")
    }

    private var fileCountText: String {
        history.changedFiles.count == 1 ? "1 file changed" : "\(history.changedFiles.count) files changed"
    }
}

private struct CommitInfoView: View {
    let commit: Commit
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.summary)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !commit.body.isEmpty {
                ScrollView {
                    Text(commit.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                row("Author", "\(commit.author.name) <\(commit.author.email)>", date: commit.author.date)
                if commit.committer.name != commit.author.name || commit.committer.email != commit.author.email {
                    row("Committer", "\(commit.committer.name) <\(commit.committer.email)>", date: commit.committer.date)
                }
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(commit.id).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.id, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the commit ID")
                    }
                }
                if !commit.parents.isEmpty {
                    GridRow {
                        Text(commit.parents.count > 1 ? "Parents" : "Parent").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(commit.parents, id: \.self) { parent in
                                Button(String(parent.prefix(7))) { select(parent) }
                                    .buttonStyle(.link)
                                    .font(.caption.monospaced())
                                    .help("Go to \(parent)")
                            }
                        }
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("history.commitInfo")
    }

    private func row(_ title: String, _ value: String, date: Date) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                Text(date, format: .dateTime.weekday().day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Diff or blame for the selected file

private struct FileContentPane: View {
    @Bindable var history: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let file = history.selectedFile {
                    Text(file.path).font(.headline).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Picker("View", selection: Binding(get: { history.fileView }, set: { view in
                    Task { await history.setFileView(view) }
                })) {
                    ForEach(HistoryModel.FileView.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(history.selectedFile == nil)
                .accessibilityIdentifier("history.fileView")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch history.fileContent {
        case .none:
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a file to see how this commit changed it, or who changed each line."))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noPreview(let message):
            ContentUnavailableView(message, systemImage: "doc")
        case .diff(let file):
            ReadOnlyDiffView(file: file)
                .id(file.path)
        case .blame(let blame):
            BlameView(blame: blame, selectedCommitID: history.selectedCommit?.id) { id in
                Task { await history.select(id) }
            }
            .id(blame.path)
        }
    }
}

/// Each line with the commit that last changed it. Runs of lines from one commit share a label, and
/// clicking a label opens that commit.
struct BlameView: View {
    let blame: Blame
    let selectedCommitID: String?
    let open: (String) -> Void

    private static let gutterWidth: CGFloat = 230

    var body: some View {
        let groups = blame.groups
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    BlameGroupView(blame: blame, group: group, isStriped: index.isMultiple(of: 2),
                                   isCurrent: group.commitID == selectedCommitID, open: open)
                }
            }
            .padding(.bottom, 8)
        }
        .background(.background)
        .accessibilityIdentifier("history.blame")
    }
}

private struct BlameGroupView: View {
    let blame: Blame
    let group: BlameGroup
    let isStriped: Bool
    let isCurrent: Bool
    let open: (String) -> Void

    var body: some View {
        let commit = blame.commits[group.commitID]
        HStack(alignment: .top, spacing: 0) {
            Button {
                if let commit, !commit.isUncommitted { open(commit.id) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    if let commit {
                        Text(commit.isUncommitted ? "Not committed yet" : commit.summary)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(commit.isUncommitted ? "" : commit.shortID).monospaced()
                            Text(commit.author.name).lineLimit(1)
                            Text(commit.author.date.compactDescription()).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(width: 230, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(commit.map { "\($0.summary)\n\($0.author.name) <\($0.author.email)>\n\($0.id)" } ?? "")
            .accessibilityLabel(commit.map { "\($0.summary) by \($0.author.name)" } ?? "Unknown commit")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.range, id: \.self) { index in
                    let line = blame.lines[index]
                    HStack(spacing: 0) {
                        Text(String(line.lineNumber))
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                            .padding(.trailing, 10)
                        Text(DiffRows.displayText(line.text).0.isEmpty ? " " : DiffRows.displayText(line.text).0)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .background(isCurrent ? Color.accentColor.opacity(0.14) : (isStriped ? Color.secondary.opacity(0.06) : .clear))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - Opening a file's history from other screens

extension EnvironmentValues {
    /// Opens the history screen on one file. Set by the repository window.
    @Entry var showFileHistory: (String) -> Void = { _ in }
}
