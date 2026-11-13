import Foundation
import GitEngine
import Observation

/// What the main repository window shows.
@MainActor
@Observable
public final class RepositoryModel: Identifiable {
    public enum Section: Hashable, Sendable {
        case changes
        case history
    }

    public let repository: Repository
    public let workingCopy: WorkingCopyModel
    public let sync: SyncModel
    public var section: Section = .changes
    public private(set) var status = RepositoryStatus()
    public private(set) var commits: [Commit] = []
    public private(set) var refs: [Ref] = []
    public private(set) var remotes: [Remote] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// The last failed branch action, for an alert. Clear it with `dismissActionError()`.
    public internal(set) var actionError: String?
    /// A short confirmation of the last branch action, such as the commit a deleted branch pointed at.
    public internal(set) var actionNotice: String?
    public internal(set) var isPerformingAction = false
    /// How many commits the history list loads.
    public var historyLimit: Int

    public nonisolated var id: URL { repository.rootURL }
    public var name: String { repository.rootURL.lastPathComponent }

    private var watcher: RepositoryWatcher?
    private var statusGeneration = 0
    private var statusRefreshRunning = false
    private var statusRefreshQueued = false

    public init(repository: Repository, historyLimit: Int = 500) {
        self.repository = repository
        self.historyLimit = historyLimit
        self.workingCopy = WorkingCopyModel(repository: repository)
        self.sync = SyncModel(repository: repository)
        sync.didFinish = { [weak self] in await self?.refresh() }
        workingCopy.reloadStatus = { [weak self] in await self?.refreshStatus() }
        workingCopy.reloadAll = { [weak self] in await self?.refresh() }
    }

    /// Reloads status, history, refs and remotes in parallel.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let repository = repository
        let limit = historyLimit
        statusGeneration += 1
        do {
            async let status = repository.status()
            async let commits = repository.log(LogQuery(limit: limit))
            async let refs = repository.refs()
            async let remotes = repository.remotes()
            (self.status, self.commits, self.refs, self.remotes) = try await (status, commits, refs, remotes)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await workingCopy.statusDidChange(status)
    }

    /// Reloads only the status (and the selected diff), which is all that changes while staging.
    public func refreshStatus() async {
        statusGeneration += 1
        let generation = statusGeneration
        do {
            let fresh = try await repository.status()
            // A newer refresh started while this one ran: let it win.
            guard generation == statusGeneration else { return }
            status = fresh
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await workingCopy.statusDidChange(status)
    }

    // MARK: Watching

    /// Refreshes the status when files change on disk, including from the terminal or another tool.
    public func startWatching() {
        guard watcher == nil else { return }
        let watcher = RepositoryWatcher(root: repository.rootURL) { [weak self] in
            Task { @MainActor in await self?.refreshAfterFileChange() }
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Runs one refresh at a time; changes arriving meanwhile cause exactly one more run.
    func refreshAfterFileChange() async {
        guard !statusRefreshRunning else { statusRefreshQueued = true; return }
        statusRefreshRunning = true
        repeat {
            statusRefreshQueued = false
            // Changes made by the app itself (staging, committing) refresh on their own and a commit
            // reloads history, so only the cheap status reload is needed here.
            await refreshStatus()
            // The branch or history may have moved too (a commit in a terminal).
            if let head = status.branch.headOID, commits.first?.id != head { await refresh() }
        } while statusRefreshQueued
        statusRefreshRunning = false
    }

    // MARK: Derived lists for the sidebar

    public var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    public var tags: [Ref] { refs.filter { $0.kind == .tag } }

    /// Remote-tracking branches grouped by remote, leaving out symbolic refs like `origin/HEAD`.
    public var remoteBranches: [(remote: String, branches: [Ref])] {
        var groups: [String: [Ref]] = [:]
        for ref in refs where ref.symbolicTarget == nil {
            if case .remoteBranch(let remote) = ref.kind { groups[remote, default: []].append(ref) }
        }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }

    /// A short description of HEAD for the toolbar: the branch, or the detached commit.
    public var headDescription: String {
        if let branch = status.branch.branch { return branch }
        if let oid = status.branch.headOID { return "Detached at \(oid.prefix(7))" }
        return "No commits yet"
    }

    /// "2 ahead, 1 behind origin/main", or nil when there's no upstream.
    public var trackingDescription: String? {
        guard let upstream = status.branch.upstream else { return nil }
        let ahead = status.branch.ahead ?? 0, behind = status.branch.behind ?? 0
        if ahead == 0 && behind == 0 { return "Up to date with \(upstream)" }
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: ", ") + " \(upstream)"
    }
}
