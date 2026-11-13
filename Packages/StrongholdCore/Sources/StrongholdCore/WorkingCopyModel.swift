import Foundation
import GitEngine
import Observation

/// Which list a changed file is shown in. A file with both staged and unstaged changes is in two lists.
public enum ChangeArea: Hashable, Sendable {
    case conflicted
    case staged
    case unstaged
}

/// One selected row of the changes list.
public struct FileSelection: Hashable, Sendable {
    public var path: String
    public var area: ChangeArea

    public init(path: String, area: ChangeArea) {
        self.path = path
        self.area = area
    }
}

/// What the diff pane shows for the selection.
public enum DiffContent: Equatable, Sendable {
    case none
    case loading
    case multiple(count: Int)
    case conflict
    case noPreview(String)
    case file(FileDiff)
}

/// The everyday loop: pick files, read their diffs, stage or discard whole files, hunks or single lines,
/// and commit.
@MainActor
@Observable
public final class WorkingCopyModel {
    public let repository: Repository

    public private(set) var status = RepositoryStatus()
    /// The files picked in the list. Change it with `select(_:)` so the diff follows.
    public private(set) var selection: Set<FileSelection> = []
    public private(set) var diff: DiffContent = .none
    /// Lines picked in the diff for line-level staging.
    public var lineSelection: Set<LineSelection> = []

    public var commitMessage = ""
    /// Whether the commit replaces the last one. Change it with `setAmend(_:)`.
    public private(set) var amend = false
    public private(set) var isBusy = false
    /// The last failed action, for an alert. Cleared with `dismissError()`.
    public private(set) var errorMessage: String?
    /// The commit made last, for a short confirmation.
    public private(set) var lastCommit: (id: String, summary: String)?

    private var draftBeforeAmend = ""
    private var diffGeneration = 0
    private var hasLoadedOnce = false

    /// Reloads just the status; called after every change to the working copy.
    var reloadStatus: @MainActor () async -> Void = {}
    /// Reloads everything, including history; called after a commit.
    var reloadAll: @MainActor () async -> Void = {}

    public init(repository: Repository) {
        self.repository = repository
    }

    // MARK: Derived lists

    public var conflicted: [StatusEntry] { status.conflicted }
    public var staged: [StatusEntry] { status.staged }
    public var unstaged: [StatusEntry] { status.unstaged }

    public var canCommit: Bool {
        guard !isBusy else { return false }
        if amend { return true }
        return !status.staged.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The single selected file, whose diff is shown.
    public var focusedSelection: FileSelection? {
        selection.count == 1 ? selection.first : nil
    }

    /// The diff of the focused file, when it is loaded.
    public var currentFile: FileDiff? {
        if case .file(let file) = diff { return file }
        return nil
    }

    public var focusedArea: ChangeArea? { focusedSelection?.area }

    /// True when the focused file's diff can be staged or discarded by line.
    public var supportsLineSelection: Bool {
        guard let file = currentFile, focusedArea != .conflicted else { return false }
        return PatchBuilder.supportsPartialChanges(file)
    }

    public func dismissError() { errorMessage = nil }

    // MARK: Selection

    /// Picks files in the list and loads the diff of the one picked, if there is just one.
    public func select(_ files: Set<FileSelection>) async {
        if files != selection {
            selection = files
            lineSelection = []
        }
        await reloadDiff()
    }

    // MARK: Status updates

    /// Takes a freshly loaded status: keeps the selection where files are still listed, picks a
    /// neighbour where one vanished, and reloads the diff.
    func statusDidChange(_ newStatus: RepositoryStatus) async {
        let old = status
        status = newStatus
        var kept = selection.filter { listed($0, in: newStatus) }
        if kept.isEmpty {
            if hasLoadedOnce, let neighbour = neighbour(of: selection, old: old, new: newStatus) {
                kept = [neighbour]
            } else if !hasLoadedOnce, let first = firstEntry(in: newStatus) {
                kept = [first]
            }
        }
        hasLoadedOnce = true
        await select(kept)
    }

    private func listed(_ selection: FileSelection, in status: RepositoryStatus) -> Bool {
        entries(in: selection.area, of: status).contains { $0.path == selection.path }
    }

    private func entries(in area: ChangeArea, of status: RepositoryStatus) -> [StatusEntry] {
        switch area {
        case .conflicted: status.conflicted
        case .staged: status.staged
        case .unstaged: status.unstaged
        }
    }

    private func firstEntry(in status: RepositoryStatus) -> FileSelection? {
        if let entry = status.conflicted.first { return FileSelection(path: entry.path, area: .conflicted) }
        if let entry = status.unstaged.first { return FileSelection(path: entry.path, area: .unstaged) }
        if let entry = status.staged.first { return FileSelection(path: entry.path, area: .staged) }
        return nil
    }

    /// After the selected file leaves its list, the file now at the same position (or the last one).
    private func neighbour(of gone: Set<FileSelection>, old: RepositoryStatus, new: RepositoryStatus) -> FileSelection? {
        guard let first = gone.first else { return nil }
        let before = entries(in: first.area, of: old)
        let after = entries(in: first.area, of: new)
        if !after.isEmpty {
            let position = before.firstIndex { $0.path == first.path } ?? 0
            return FileSelection(path: after[min(position, after.count - 1)].path, area: first.area)
        }
        return firstEntry(in: new)
    }

    // MARK: Diff

    func reloadDiff() async {
        diffGeneration += 1
        let generation = diffGeneration
        guard let focus = focusedSelection else {
            diff = selection.isEmpty ? .none : .multiple(count: selection.count)
            return
        }
        guard let entry = status.entries.first(where: { $0.path == focus.path }) else {
            diff = .none
            return
        }
        if focus.area == .conflicted {
            diff = .conflict
            return
        }
        if case .file = diff {} else { diff = .loading }
        let repository = repository
        do {
            let files: [FileDiff]
            switch focus.area {
            case .staged:
                files = try await repository.diff(.staged, paths: [entry.path] + (entry.originalPath.map { [$0] } ?? []))
            case .unstaged where entry.kind == .untracked:
                files = try await repository.untrackedDiff(for: entry.path)
            default:
                files = try await repository.diff(.workTree, paths: [entry.path])
            }
            guard generation == diffGeneration else { return }
            if let file = files.first(where: { $0.path == entry.path }) ?? files.first {
                // Picked lines are positions in the old diff: keep them only if nothing changed.
                if currentFile != file { lineSelection = [] }
                if file.isBinary {
                    diff = .noPreview("Binary file")
                } else if file.hunks.isEmpty {
                    diff = .noPreview(Self.describeEmpty(file))
                } else {
                    diff = .file(file)
                }
            } else if entry.submodule != nil {
                diff = .noPreview("Submodule")
            } else if entry.kind == .untracked {
                diff = .noPreview(entry.path.hasSuffix("/") ? "Untracked folder" : "Empty file")
            } else {
                diff = .noPreview("No textual changes")
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == diffGeneration else { return }
            diff = .noPreview(error.localizedDescription)
        }
    }

    private static func describeEmpty(_ file: FileDiff) -> String {
        switch file.change {
        case .added: "Empty file"
        case .deleted: "Empty file deleted"
        case .renamed, .copied: "Renamed with no other changes"
        case .modified: file.oldMode != file.newMode ? "File mode changed" : "No textual changes"
        }
    }

    // MARK: Whole files

    public func stage(_ paths: [String]) async {
        await perform { try await $0.stage(paths) }
    }

    public func unstage(_ entries: [StatusEntry]) async {
        // A staged rename is two paths in the index; both must be restored to undo it.
        let paths = entries.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        await perform { try await $0.unstage(paths) }
    }

    public func stageAll() async {
        await perform { try await $0.stageAll() }
    }

    public func unstageAll() async {
        let paths = status.staged.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        await perform { try await $0.unstage(paths) }
    }

    /// Stages the entries chosen in the list.
    public func stage(_ selections: Set<FileSelection>) async {
        await stage(selections.filter { $0.area == .unstaged }.map(\.path).sorted())
    }

    public func unstage(_ selections: Set<FileSelection>) async {
        let paths = Set(selections.filter { $0.area == .staged }.map(\.path))
        await unstage(status.entries.filter { paths.contains($0.path) })
    }

    /// Throws away the unstaged changes of `paths`, deleting untracked files. The caller confirms first.
    public func discard(paths: Set<String>) async {
        let entries = status.entries.filter { paths.contains($0.path) && $0.hasUnstagedChanges }
        let untracked = entries.filter { $0.kind == .untracked }.map(\.path)
        let tracked = entries.filter { $0.kind != .untracked }.map(\.path)
        await perform { try await $0.discardChanges(tracked: tracked, untracked: untracked) }
    }

    /// Discards every unstaged change. The caller confirms first.
    public func discardAll() async {
        await discard(paths: Set(status.unstaged.map(\.path)))
    }

    // MARK: Hunks and lines

    /// Stages (in the unstaged area) or unstages (in the staged area) the picked lines.
    public func applySelectedLines() async {
        await applyLines(lineSelection)
    }

    /// Stages or unstages every changed line of one hunk.
    public func applyHunk(_ index: Int) async {
        guard let file = currentFile else { return }
        await applyLines(PatchBuilder.hunkSelection(of: file, hunk: index))
    }

    /// Stages or unstages the whole file through patches; used for files shown line by line.
    private func applyLines(_ lines: Set<LineSelection>) async {
        guard let file = currentFile, let area = focusedArea, !lines.isEmpty else { return }
        switch area {
        case .unstaged: await perform { try await $0.stageLines(of: file, lines) }
        case .staged: await perform { try await $0.unstageLines(of: file, lines) }
        case .conflicted: break
        }
    }

    /// Reverts the picked lines in the work tree. The caller confirms first.
    public func discardSelectedLines() async {
        await discardLines(lineSelection)
    }

    public func discardHunk(_ index: Int) async {
        guard let file = currentFile else { return }
        await discardLines(PatchBuilder.hunkSelection(of: file, hunk: index))
    }

    private func discardLines(_ lines: Set<LineSelection>) async {
        guard let file = currentFile, focusedArea == .unstaged, !lines.isEmpty else { return }
        await perform { try await $0.discardLines(of: file, lines) }
    }

    /// Picks or unpicks one changed line.
    public func toggleLine(_ line: LineSelection) {
        if lineSelection.contains(line) { lineSelection.remove(line) } else { lineSelection.insert(line) }
    }

    /// Picks or unpicks every changed line of a hunk.
    public func toggleHunk(_ index: Int) {
        guard let file = currentFile else { return }
        let all = PatchBuilder.hunkSelection(of: file, hunk: index)
        if all.isSubset(of: lineSelection) { lineSelection.subtract(all) } else { lineSelection.formUnion(all) }
    }

    // MARK: Committing

    /// Commits the index (or amends HEAD) with the typed message.
    @discardableResult
    public func commit() async -> Bool {
        guard canCommit else { return false }
        let message = commitMessage
        let amending = amend
        isBusy = true
        defer { isBusy = false }
        do {
            let id = try await repository.commit(message: message, amend: amending)
            let summary = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            lastCommit = (id, summary)
            commitMessage = ""
            draftBeforeAmend = ""
            amend = false
            errorMessage = nil
            await reloadAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Turns amending on or off. Turning it on fills an empty message box with the last commit's message;
    /// turning it off brings back what was typed before.
    public func setAmend(_ on: Bool) async {
        guard on != amend else { return }
        amend = on
        if amend {
            draftBeforeAmend = commitMessage
            if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let message = try? await repository.headMessage() {
                commitMessage = message
            }
        } else {
            commitMessage = draftBeforeAmend
            draftBeforeAmend = ""
        }
    }

    // MARK: Plumbing

    private func perform(_ action: @Sendable (Repository) async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        do {
            try await action(repository)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
        await reloadStatus()
    }
}
