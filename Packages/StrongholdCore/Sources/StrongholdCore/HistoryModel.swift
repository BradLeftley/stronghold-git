import Foundation
import GitEngine
import Observation

/// The history screen: the commit graph, search, a file's history, and the selected commit's details,
/// diffs and blame.
@MainActor
@Observable
public final class HistoryModel {
    public enum Scope: String, CaseIterable, Hashable, Sendable {
        case currentBranch
        case allBranches

        public var label: String {
            switch self {
            case .currentBranch: "Current Branch"
            case .allBranches: "All Branches"
            }
        }
    }

    public enum SearchField: String, CaseIterable, Hashable, Sendable {
        case message
        case author
        case file
        case content

        public var label: String {
            switch self {
            case .message: "Message"
            case .author: "Author"
            case .file: "File"
            case .content: "Content"
            }
        }

        public var prompt: String {
            switch self {
            case .message: "Search commit messages"
            case .author: "Search by author name or email"
            case .file: "Search by file or folder name"
            case .content: "Find commits adding or removing text"
            }
        }
    }

    /// One row of the list.
    public struct Row: Identifiable, Equatable, Sendable {
        public var commit: Commit
        /// In a file's history, the file's name in this commit.
        public var path: String?
        public var id: String { commit.id }
    }

    /// What the bottom-right pane shows for the selected file.
    public enum FileContent: Equatable, Sendable {
        case none
        case loading
        case diff(FileDiff)
        case blame(Blame)
        case noPreview(String)
    }

    public enum FileView: String, CaseIterable, Hashable, Sendable {
        case diff
        case blame

        public var label: String {
            switch self {
            case .diff: "Changes"
            case .blame: "Blame"
            }
        }
    }

    public let repository: Repository
    public let pageSize: Int

    public private(set) var scope: Scope = .currentBranch
    public private(set) var rows: [Row] = []
    /// Branch lines for `rows`. Nil while searching or showing a file's history, where the rows aren't
    /// a connected history.
    public private(set) var graph: CommitGraph?
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    /// More commits exist past the last row.
    public private(set) var canLoadMore = false
    public private(set) var errorMessage: String?

    /// What the list is filtered by. In a file's history it filters the file's commits by message or
    /// author without asking git again.
    public private(set) var searchText = ""
    public private(set) var searchField: SearchField = .message
    /// When set, the list is this file's history.
    public private(set) var filePath: String?
    /// The whole of the file's history, before `searchText` filters it.
    private var fileHistoryRows: [Row] = []

    public private(set) var selectedCommit: Commit?
    public private(set) var changedFiles: [CommitFileChange] = []
    public private(set) var isLoadingFiles = false
    public private(set) var selectedFile: CommitFileChange?
    public private(set) var fileView: FileView = .diff
    public private(set) var fileContent: FileContent = .none

    private var listGeneration = 0
    private var detailGeneration = 0
    private var fileGeneration = 0

    public init(repository: Repository, pageSize: Int = 500) {
        self.repository = repository
        self.pageSize = max(1, pageSize)
    }

    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A line describing what the list shows, for the header.
    public var listDescription: String {
        let count = rows.count == 1 ? "1 commit" : "\(rows.count)\(canLoadMore ? "+" : "") commits"
        if let filePath {
            return isSearching ? "History of \(filePath) · \(count) matching “\(searchText)”" : "History of \(filePath) · \(count)"
        }
        if isSearching { return "\(count) matching “\(searchText)”" }
        return "\(scope.label) · \(count)"
    }

    // MARK: Loading the list

    /// Loads the first page again, keeping the selection if the commit is still there.
    public func reload() async {
        await load(reset: true)
    }

    /// Loads the list again after branches move, keeping as many commits as were loaded so the
    /// selection and your place in a long history stay put.
    public func refresh() async {
        await load(reset: true, keepingCount: true)
    }

    /// Loads the next page of commits. File histories load all at once.
    public func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        await load(reset: false)
    }

    public func setScope(_ scope: Scope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        await reload()
    }

    /// Filters the list. An empty text shows the full history again. In a file's history the text
    /// matches the commit message or author, whatever the field.
    public func search(_ text: String, in field: SearchField) async {
        guard text != searchText || field != searchField else { return }
        searchText = text
        searchField = field
        if filePath != nil {
            // A load in progress filters its result with the new text when it lands.
            guard hasLoaded, !isLoading else { return }
            rows = Self.filter(fileHistoryRows, by: searchText)
            await keepSelectionAfterReload()
        } else {
            await reload()
        }
    }

    /// Shows the history of one file, following it back through renames. Starts with no search.
    public func showFileHistory(of path: String) async {
        filePath = path
        searchText = ""
        await reload()
    }

    /// Goes back to the full history, with no search.
    public func clearFileHistory() async {
        guard filePath != nil else { return }
        filePath = nil
        fileHistoryRows = []
        searchText = ""
        await reload()
    }

    /// The rows whose message, author name or author email contain `text`, ignoring case.
    static func filter(_ rows: [Row], by text: String) -> [Row] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return rows }
        return rows.filter { row in
            let commit = row.commit
            return [commit.message, commit.author.name, commit.author.email].contains {
                $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private func load(reset: Bool, keepingCount: Bool = false) async {
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        defer { if generation == listGeneration { isLoading = false } }
        let repository = repository
        let skip = reset ? 0 : rows.count
        do {
            let fresh: [Row]
            var more = false
            var fileHistory: [Row] = []
            if let filePath {
                let entries = try await repository.fileHistory(of: filePath)
                fileHistory = entries.map { Row(commit: $0.commit, path: $0.path) }
                fresh = Self.filter(fileHistory, by: searchText)
            } else {
                var limit = keepingCount ? max(pageSize, rows.count) : pageSize
                var commits = try await repository.log(makeQuery(skip: skip, limit: limit))
                // New commits can push the selected one past the old count: load a few more pages
                // to get it back, so the selection doesn't jump to the top.
                if keepingCount, let selectedID = selectedCommit?.id, rows.contains(where: { $0.id == selectedID }) {
                    var extraPages = 0
                    while commits.count > limit, extraPages < 4, !commits.prefix(limit).contains(where: { $0.id == selectedID }) {
                        extraPages += 1
                        limit += pageSize
                        commits = try await repository.log(makeQuery(skip: skip, limit: limit))
                    }
                }
                more = commits.count > limit
                fresh = commits.prefix(limit).map { Row(commit: $0, path: nil) }
            }
            guard generation == listGeneration else { return }
            fileHistoryRows = fileHistory
            let all = reset ? fresh : rows + fresh
            let graph: CommitGraph?
            if filePath == nil && !isSearching {
                let commits = all.map(\.commit)
                graph = await Task.detached(priority: .userInitiated) { CommitGraph(commits) }.value
            } else {
                graph = nil
            }
            guard generation == listGeneration else { return }
            rows = all
            self.graph = graph
            canLoadMore = more
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == listGeneration else { return }
            errorMessage = error.localizedDescription
            return
        }
        if reset { await keepSelectionAfterReload() }
    }

    /// The `git log` query for the current scope and search. Asks for one more than `limit` (a page
    /// unless given) so it can tell whether more exist.
    func makeQuery(skip: Int, limit: Int? = nil) -> LogQuery {
        var query = LogQuery(allRefs: scope == .allBranches, limit: (limit ?? pageSize) + 1, skip: skip,
                             topologicalOrder: true)
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return query }
        // Search results come newest first; only the full graph needs topological order.
        query.topologicalOrder = false
        switch searchField {
        case .message: query.messagePattern = text
        case .author: query.authorPattern = text
        case .file: query.paths = LogQuery.pathsContaining(text)
        case .content: query.contentPattern = text
        }
        return query
    }

    private func keepSelectionAfterReload() async {
        if let selected = selectedCommit, let row = rows.first(where: { $0.id == selected.id }) {
            if filePath != nil, let path = row.path, selectedFile?.path != path {
                await select(row.id)
            }
            return
        }
        // Otherwise start on the newest commit, as a freshly opened history does.
        if let first = rows.first { await select(first.id) } else { clearSelection() }
    }

    // MARK: Selection

    public func clearSelection() {
        detailGeneration += 1
        fileGeneration += 1
        selectedCommit = nil
        changedFiles = []
        selectedFile = nil
        fileContent = .none
    }

    /// Selects a commit and loads the files it changed. The commit doesn't have to be in the list, so a
    /// blame line can jump to any commit.
    public func select(_ commitID: String?) async {
        guard let commitID else { clearSelection(); return }
        detailGeneration += 1
        let generation = detailGeneration
        let row = rows.first { $0.id == commitID }
        do {
            let commit: Commit
            if let row { commit = row.commit } else { commit = try await repository.commit(commitID) }
            guard generation == detailGeneration else { return }
            selectedCommit = commit
            changedFiles = []
            isLoadingFiles = true
            let files = try await repository.changedFiles(in: commit)
            guard generation == detailGeneration else { return }
            changedFiles = files
            isLoadingFiles = false
            // In a file's history, open that file; otherwise keep the same file open if this commit
            // touched it too, so stepping through commits keeps your place.
            let preferred = row?.path ?? selectedFile?.path
            let file = files.first { $0.path == preferred } ?? (filePath != nil ? files.first : nil)
            await selectFile(file)
        } catch is CancellationError {
            return
        } catch {
            guard generation == detailGeneration else { return }
            isLoadingFiles = false
            errorMessage = error.localizedDescription
        }
    }

    /// The commit below or above the selected one, for arrow-key navigation.
    public func neighbour(_ offset: Int) -> String? {
        guard let selected = selectedCommit, let index = rows.firstIndex(where: { $0.id == selected.id }) else {
            return rows.first?.id
        }
        let target = index + offset
        return rows.indices.contains(target) ? rows[target].id : nil
    }

    public func selectFile(_ file: CommitFileChange?) async {
        selectedFile = file
        await loadFileContent()
    }

    public func setFileView(_ view: FileView) async {
        guard view != fileView else { return }
        fileView = view
        await loadFileContent()
    }

    private func loadFileContent() async {
        fileGeneration += 1
        let generation = fileGeneration
        guard let file = selectedFile, let commit = selectedCommit else { fileContent = .none; return }
        fileContent = .loading
        let repository = repository
        let view = fileView
        do {
            let content: FileContent
            switch view {
            case .diff:
                if let diff = try await repository.diff(of: file, in: commit) {
                    content = diff.isBinary ? .noPreview("Binary file") : .diff(diff)
                } else {
                    content = .noPreview("No changes to show")
                }
            case .blame:
                if file.change == .deleted {
                    content = .noPreview("The file was deleted in this commit")
                } else {
                    content = .blame(try await repository.blame(file.path, at: commit.id))
                }
            }
            guard generation == fileGeneration else { return }
            fileContent = content
        } catch is CancellationError {
            return
        } catch {
            guard generation == fileGeneration else { return }
            fileContent = .noPreview(error.localizedDescription)
        }
    }
}
