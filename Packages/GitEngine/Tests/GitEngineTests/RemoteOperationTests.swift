import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferProgress] = []
    func add(_ item: TransferProgress) { lock.withLock { items.append(item) } }
    var all: [TransferProgress] { lock.withLock { items } }
}

@Suite("Fetch, pull and push")
struct RemoteOperationTests {
    // MARK: Fetch

    @Test func fetchBringsInNewCommitsWithoutTouchingTheBranch() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        let pushed = try await mate.commit("from mate", files: ["m.txt": "m"])
        try await mate.git("push", "origin", "main")

        let repo = pair.local.repository
        let before = try await repo.resolve("HEAD")
        try await repo.fetch()
        #expect(try await repo.resolve("HEAD") == before)
        #expect(try await repo.resolve("origin/main") == pushed)
    }

    @Test func fetchPrunesDeletedRemoteBranches() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.git("push", "origin", "main:refs/heads/gone")
        try await pair.local.repository.fetch()
        #expect(try await pair.local.repository.resolve("origin/gone") != nil)
        try await mate.git("push", "origin", "--delete", "gone")
        try await pair.local.repository.fetch(FetchOptions(prune: false))
        #expect(try await pair.local.repository.resolve("origin/gone") != nil)
        try await pair.local.repository.fetch(FetchOptions(prune: true))
        #expect(try await pair.local.repository.resolve("origin/gone") == nil)
    }

    @Test func fetchWithNoRemoteSaysSo() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("x")
        await #expect(throws: GitError.remoteFailed(.noRemote, detail: "")) { try await tmp.repository.fetch() }
    }

    @Test func fetchFromAMissingRemoteIsClassified() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.git("remote", "add", "origin", tmp.baseURL.appendingPathComponent("nowhere").path)
        do {
            try await tmp.repository.fetch()
            Issue.record("expected a failure")
        } catch let GitError.remoteFailed(failure, detail) {
            #expect(failure == .repositoryNotFound)
            #expect(!detail.isEmpty)
        }
    }

    @Test func fetchReportsProgressWhenGitSendsAny() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        for i in 0..<5 { try await mate.commit("c\(i)", files: ["f\(i).txt": String(repeating: "line \(i)\n", count: 200)]) }
        try await mate.git("push", "origin", "main")
        let collected = Collected()
        try await pair.local.repository.fetch(onProgress: { collected.add($0) })
        // git decides whether a local transfer is worth reporting; whatever arrives must be well formed.
        for item in collected.all {
            #expect(item.percent >= 0 && item.percent <= 100)
            #expect(!item.phase.isEmpty)
        }
    }

    // MARK: Pull

    @Test func pullFastForwards() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        let pushed = try await mate.commit("from mate", files: ["m.txt": "m"])
        try await mate.git("push", "origin", "main")

        let result = try await pair.local.repository.pull()
        #expect(!result.alreadyUpToDate)
        #expect(try await pair.local.repository.resolve("HEAD") == pushed)
        #expect(try pair.local.read("m.txt") == "m")
    }

    @Test func pullWhenCurrentSaysSo() async throws {
        let pair = try await TemporaryRemotePair()
        let result = try await pair.local.repository.pull()
        #expect(result.alreadyUpToDate)
    }

    @Test func pullMergesDivergedHistory() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["theirs.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["ours.txt": "o"])

        try await pair.local.repository.pull(PullOptions(strategy: .merge))
        let status = try await pair.local.repository.status()
        #expect(status.branch.behind == 0)
        #expect(status.branch.ahead == 2) // our commit and the merge
        #expect(try pair.local.read("theirs.txt") == "t")
        #expect(try pair.local.read("ours.txt") == "o")
    }

    @Test func pullRebasesLocalCommitsOntoTheRemote() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        let theirs = try await mate.commit("theirs", files: ["theirs.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["ours.txt": "o"])

        try await pair.local.repository.pull(PullOptions(strategy: .rebase))
        let log = try await pair.local.repository.log()
        #expect(log.map(\.summary) == ["ours", "theirs", "first"])
        #expect(log[1].id == theirs)
        #expect(log[0].parents.count == 1)
    }

    @Test func fastForwardOnlyRefusesDivergedHistoryWithAdvice() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["theirs.txt": "t"])
        try await mate.git("push", "origin", "main")
        let ours = try await pair.local.commit("ours", files: ["ours.txt": "o"])
        do {
            try await pair.local.repository.pull(PullOptions(strategy: .fastForwardOnly))
            Issue.record("expected a failure")
        } catch let GitError.remoteFailed(failure, _) {
            #expect(failure == .cannotFastForward)
        }
        #expect(try await pair.local.repository.resolve("HEAD") == ours)
    }

    @Test func pullConflictIsReportedAndLeavesTheMergeInProgress() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["a.txt": "theirs\n"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["a.txt": "ours\n"])
        do {
            try await pair.local.repository.pull(PullOptions(strategy: .merge))
            Issue.record("expected a conflict")
        } catch let GitError.remoteFailed(failure, detail) {
            #expect(failure == .mergeConflict)
            #expect(detail.contains("CONFLICT"))
        }
        let status = try await pair.local.repository.status()
        #expect(!status.conflicted.isEmpty)
    }

    @Test func pullWithLocalChangesInTheWayIsClassified() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["a.txt": "theirs\n"])
        try await mate.git("push", "origin", "main")
        try pair.local.write("a.txt", "dirty\n")
        do {
            try await pair.local.repository.pull()
            Issue.record("expected a failure")
        } catch let GitError.remoteFailed(failure, _) {
            #expect(failure == .localChangesInTheWay)
        }
        #expect(try pair.local.read("a.txt") == "dirty\n")
    }

    @Test func autostashCarriesLocalChangesThroughAPull() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["m.txt": "m\n"])
        try await mate.git("push", "origin", "main")
        try pair.local.write("a.txt", "dirty\n")
        try await pair.local.repository.pull(PullOptions(strategy: .merge, autostash: true))
        #expect(try pair.local.read("a.txt") == "dirty\n")
        #expect(try pair.local.read("m.txt") == "m\n")
    }

    @Test func pullWithoutAnUpstreamIsClassified() async throws {
        let pair = try await TemporaryRemotePair()
        try await pair.local.repository.createBranch("lonely")
        do {
            try await pair.local.repository.pull()
            Issue.record("expected a failure")
        } catch let GitError.remoteFailed(failure, _) {
            #expect(failure == .noUpstream)
        }
    }

    @Test func defaultStrategyFollowsConfig() async throws {
        let tmp = try await TemporaryRepository()
        #expect(try await tmp.repository.defaultPullStrategy() == .merge)
        try await tmp.repository.setConfig("pull.rebase", to: "true")
        #expect(try await tmp.repository.defaultPullStrategy() == .rebase)
        try await tmp.repository.setConfig("pull.rebase", to: "false")
        try await tmp.repository.setConfig("pull.ff", to: "only")
        #expect(try await tmp.repository.defaultPullStrategy() == .fastForwardOnly)
    }

    // MARK: Push

    @Test func firstPushPublishesTheBranchAndSetsTheUpstream() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        try await repo.createBranch("feature/new")
        let tip = try await pair.local.commit("work", files: ["w.txt": "w"])
        let result = try await repo.push()
        #expect(result.setUpstream)
        #expect(result.remote == "origin")
        #expect(try await pair.origin.repository.resolve("refs/heads/feature/new") == tip)
        let branch = try await repo.localBranches().first { $0.shortName == "feature/new" }
        #expect(branch?.upstream == "refs/remotes/origin/feature/new")
        #expect(branch?.ahead == 0)
    }

    @Test func laterPushesGoToTheUpstream() async throws {
        let pair = try await TemporaryRemotePair()
        let tip = try await pair.local.commit("more", files: ["b.txt": "b"])
        let result = try await pair.local.repository.push()
        #expect(!result.setUpstream)
        #expect(try await pair.origin.repository.resolve("refs/heads/main") == tip)
    }

    @Test func pushingWhenNothingIsNewSaysSo() async throws {
        let pair = try await TemporaryRemotePair()
        #expect(try await pair.local.repository.push().alreadyUpToDate)
    }

    @Test func pushHonoursAnUpstreamWithADifferentName() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        try await repo.createBranch("local-name")
        try await pair.local.git("push", "origin", "local-name:refs/heads/server-name")
        try await repo.setUpstream(of: "local-name", to: "origin/server-name")
        let tip = try await pair.local.commit("x", files: ["x.txt": "x"])
        let result = try await repo.push()
        #expect(result.branch == "server-name")
        #expect(try await pair.origin.repository.resolve("refs/heads/server-name") == tip)
        #expect(try await pair.origin.repository.resolve("refs/heads/local-name") == nil)
    }

    @Test func rejectedPushExplainsToPullFirst() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["o.txt": "o"])
        do {
            try await pair.local.repository.push()
            Issue.record("expected a rejection")
        } catch let error as GitError {
            guard case .remoteFailed(let failure, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(failure == .pushRejectedNonFastForward)
            #expect(error.localizedDescription.contains("Pull first"))
        }
    }

    @Test func forceWithLeaseOverwritesOnlyWhenTheRemoteIsAsExpected() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        // Rewrite our last commit, so a plain push is rejected.
        try await pair.local.git("commit", "--amend", "--allow-empty", "-m", "rewritten")
        await #expect(throws: GitError.self) { try await repo.push() }
        let result = try await repo.push(PushOptions(forceWithLease: true))
        #expect(!result.alreadyUpToDate)
        #expect(try await pair.origin.repository.resolve("refs/heads/main") == repo.resolve("HEAD"))
    }

    @Test func forceWithLeaseRefusesWhenSomeoneElsePushedMeanwhile() async throws {
        let pair = try await TemporaryRemotePair()
        let mate = try await pair.makeTeammate()
        let theirs = try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.git("commit", "--amend", "--allow-empty", "-m", "rewritten")
        // We never fetched, so our lease is stale.
        await #expect(throws: GitError.self) { try await pair.local.repository.push(PushOptions(forceWithLease: true)) }
        #expect(try await pair.origin.repository.resolve("refs/heads/main") == theirs)
    }

    @Test func pushWithNoRemoteIsClassified() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("x")
        await #expect(throws: GitError.remoteFailed(.noRemote, detail: "")) { try await tmp.repository.push() }
    }

    @Test func pushingADetachedHeadIsRefused() async throws {
        let pair = try await TemporaryRemotePair()
        try await pair.local.repository.switchDetached(to: "HEAD")
        await #expect(throws: GitError.self) { try await pair.local.repository.push() }
    }

    @Test func choosesTheOnlyRemoteWhenThereIsNoOrigin() async throws {
        let pair = try await TemporaryRemotePair(seed: false)
        try await pair.local.commit("first", files: ["a.txt": "1"])
        try await pair.local.git("remote", "rename", "origin", "upstream")
        let result = try await pair.local.repository.push()
        #expect(result.remote == "upstream")
    }

    @Test func asksWhichRemoteWhenThereAreSeveralAndNoOrigin() async throws {
        let pair = try await TemporaryRemotePair(seed: false)
        try await pair.local.commit("first", files: ["a.txt": "1"])
        try await pair.local.git("remote", "rename", "origin", "one")
        try await pair.local.git("remote", "add", "two", pair.origin.path)
        await #expect(throws: GitError.self) { try await pair.local.repository.push() }
        let result = try await pair.local.repository.push(PushOptions(remote: "two"))
        #expect(result.remote == "two")
    }

    @Test func deletesARemoteBranch() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        try await repo.createBranch("temp")
        try await repo.push()
        #expect(try await pair.origin.repository.resolve("refs/heads/temp") != nil)
        try await repo.deleteRemoteBranch(remote: "origin", branch: "temp")
        #expect(try await pair.origin.repository.resolve("refs/heads/temp") == nil)
    }

    // MARK: Safety

    @Test func cancellingStopsTheOperation() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        let task = Task { try await repo.fetch() }
        task.cancel()
        // Whether it was cancelled before or after git finished, the result is a clean outcome, never a hang.
        _ = await task.result
    }

    @Test func remoteCommandsAreRestrictedToSafeTransports() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("x")
        // A repository whose remote runs a command through the ext:: transport must not run it.
        let marker = tmp.baseURL.appendingPathComponent("pwned")
        try await tmp.git("remote", "add", "evil", "ext::sh -c 'touch \(marker.path)'")
        await #expect(throws: GitError.self) { try await tmp.repository.fetch(FetchOptions(remote: "evil")) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
