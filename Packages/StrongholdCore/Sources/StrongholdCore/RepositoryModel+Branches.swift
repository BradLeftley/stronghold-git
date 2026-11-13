import Foundation
import GitEngine

/// What the delete-branch flow found out.
public enum BranchDeletion: Equatable, Sendable {
    case deleted(tip: String?)
    /// The branch has commits that exist nowhere else; deleting needs the person's say-so.
    case needsForce
    case failed
}

extension RepositoryModel {
    public func dismissActionError() { actionError = nil }
    public func dismissActionNotice() { actionNotice = nil }

    /// Runs a branch action, reloads everything, and records a failure for the alert.
    @discardableResult
    func perform(_ action: @Sendable (Repository) async throws -> Void) async -> Bool {
        guard !isPerformingAction else { return false }
        isPerformingAction = true
        actionError = nil
        actionNotice = nil
        var succeeded = false
        do {
            try await action(repository)
            succeeded = true
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
        // Even a failed switch can change things (a half-applied operation), so always reload.
        await refresh()
        isPerformingAction = false
        return succeeded
    }

    public func createBranch(_ name: String, from startPoint: String? = nil, checkout: Bool = true) async -> Bool {
        await perform { try await $0.createBranch(name, from: startPoint, checkout: checkout) }
    }

    /// Switches to a local or remote-tracking branch, or detaches HEAD for a tag.
    public func switchTo(_ ref: Ref) async {
        await perform { repository in
            switch ref.kind {
            case .localBranch: try await repository.switchBranch(to: ref.shortName)
            case .remoteBranch: try await repository.switchToRemoteBranch(ref.shortName)
            case .tag, .other: try await repository.switchDetached(to: ref.shortName)
            }
        }
    }

    public func renameBranch(_ old: String, to new: String) async -> Bool {
        await perform { try await $0.renameBranch(old, to: new) }
    }

    /// Deletes a local branch. A branch with unmerged commits comes back as `.needsForce` without any
    /// error being shown, so the view can ask first.
    public func deleteBranch(_ name: String, force: Bool = false) async -> BranchDeletion {
        guard !isPerformingAction else { return .failed }
        isPerformingAction = true
        actionError = nil
        actionNotice = nil
        defer { isPerformingAction = false }
        do {
            let tip = try await repository.deleteBranch(name, force: force)
            actionNotice = tip.map { "Deleted branch \(name) (it pointed at \($0.prefix(7)))." } ?? "Deleted branch \(name)."
            await refresh()
            return .deleted(tip: tip)
        } catch GitError.commandFailed(_, _, let stderr) where !force && stderr.contains("not fully merged") {
            return .needsForce
        } catch {
            actionError = error.localizedDescription
            return .failed
        }
    }

    public func setUpstream(of branch: String, to upstream: String?) async {
        await perform { repository in
            if let upstream { try await repository.setUpstream(of: branch, to: upstream) } else { try await repository.unsetUpstream(of: branch) }
        }
    }

    // MARK: Derived

    /// Remote-tracking branches, as `origin/main`, that a local branch could track.
    public var upstreamCandidates: [String] {
        remoteBranches.flatMap { $0.branches.map(\.shortName) }
    }

    /// Commits to push and to pull for the current branch.
    public var currentAhead: Int { status.branch.ahead ?? 0 }
    public var currentBehind: Int { status.branch.behind ?? 0 }
    public var hasRemote: Bool { !remotes.isEmpty }
    public var hasUpstream: Bool { status.branch.upstream != nil }
    /// Pushing makes sense: there are commits to send, or the branch hasn't been published.
    public var canPush: Bool {
        guard status.branch.branch != nil, hasRemote else { return false }
        return !hasUpstream || currentAhead > 0
    }
}
