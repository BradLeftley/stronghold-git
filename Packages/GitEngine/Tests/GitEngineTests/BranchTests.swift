import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

@Suite("Branches")
struct BranchTests {
    private func repoWithCommit() async throws -> TemporaryRepository {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("first", files: ["a.txt": "one\n"])
        return tmp
    }

    // MARK: Names

    @Test(arguments: ["", "-x", "a b", "a..b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "/a", "a/", "a//b",
                      "a.", "a.lock", "x/.hidden", "@", "a@{b", "tab\there"])
    func rejectsBadNames(name: String) {
        #expect(BranchName.problem(in: name) != nil)
    }

    @Test(arguments: ["main", "feature/login", "fix-123", "release/1.2.3", "ünï", "a@b", "v1.0"])
    func acceptsGoodNames(name: String) async throws {
        #expect(BranchName.problem(in: name) == nil)
        // Our rules never accept something git rejects.
        let tmp = try await TemporaryRepository()
        let result = try await tmp.git.run(["check-ref-format", "--branch", name], in: tmp.url)
        #expect(result.succeeded)
    }

    @Test func badNameIsRefusedBeforeGitRuns() async throws {
        let tmp = try await repoWithCommit()
        await #expect(throws: GitError.self) { try await tmp.repository.createBranch("bad name") }
        #expect(try await tmp.repository.localBranches().map(\.shortName) == ["main"])
    }

    // MARK: Create and switch

    @Test func createsAndChecksOutABranch() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.createBranch("feature/x")
        #expect(try await tmp.repository.currentBranch() == "feature/x")
        #expect(try await tmp.repository.localBranches().map(\.shortName).sorted() == ["feature/x", "main"])
    }

    @Test func createsWithoutCheckingOutAtAStartPoint() async throws {
        let tmp = try await repoWithCommit()
        let first = try await tmp.repository.resolve("HEAD")
        try await tmp.commit("second", files: ["b.txt": "two\n"])
        try await tmp.repository.createBranch("old", from: first!, checkout: false)
        #expect(try await tmp.repository.currentBranch() == "main")
        let old = try await tmp.repository.localBranches().first { $0.shortName == "old" }
        #expect(old?.target == first)
    }

    @Test func creatingAnExistingBranchFails() async throws {
        let tmp = try await repoWithCommit()
        await #expect(throws: GitError.self) { try await tmp.repository.createBranch("main") }
    }

    @Test func switchesBetweenBranchesAndCarriesCleanChanges() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.createBranch("other", checkout: false)
        try tmp.write("untracked.txt", "x")
        try await tmp.repository.switchBranch(to: "other")
        #expect(try await tmp.repository.currentBranch() == "other")
        #expect(try tmp.read("untracked.txt") == "x")
    }

    @Test func switchRefusesWhenChangesWouldBeOverwritten() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.createBranch("other")
        try await tmp.commit("change", files: ["a.txt": "other\n"])
        try await tmp.repository.switchBranch(to: "main")
        try tmp.write("a.txt", "dirty\n")
        await #expect(throws: GitError.self) { try await tmp.repository.switchBranch(to: "other") }
        #expect(try await tmp.repository.currentBranch() == "main")
        #expect(try tmp.read("a.txt") == "dirty\n")
    }

    @Test func switchesDetached() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.switchDetached(to: "HEAD")
        #expect(try await tmp.repository.currentBranch() == nil)
    }

    // MARK: Rename and delete

    @Test func renamesTheCurrentBranch() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.renameBranch("main", to: "trunk")
        #expect(try await tmp.repository.currentBranch() == "trunk")
        #expect(try await tmp.repository.resolve("refs/heads/main") == nil)
    }

    @Test func renameToAnExistingNameFails() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.createBranch("other", checkout: false)
        await #expect(throws: GitError.self) { try await tmp.repository.renameBranch("other", to: "main") }
    }

    @Test func deletesAMergedBranchAndReturnsItsTip() async throws {
        let tmp = try await repoWithCommit()
        let head = try await tmp.repository.resolve("HEAD")
        try await tmp.repository.createBranch("done", checkout: false)
        let tip = try await tmp.repository.deleteBranch("done")
        #expect(tip == head)
        #expect(try await tmp.repository.resolve("refs/heads/done") == nil)
    }

    @Test func unmergedBranchNeedsForce() async throws {
        let tmp = try await repoWithCommit()
        try await tmp.repository.createBranch("wip")
        let work = try await tmp.commit("wip work", files: ["w.txt": "w"])
        try await tmp.repository.switchBranch(to: "main")
        await #expect(throws: GitError.self) { try await tmp.repository.deleteBranch("wip") }
        #expect(try await tmp.repository.resolve("refs/heads/wip") == work)
        let tip = try await tmp.repository.deleteBranch("wip", force: true)
        #expect(tip == work)
        #expect(try await tmp.repository.resolve("refs/heads/wip") == nil)
    }

    @Test func cannotDeleteTheCheckedOutBranch() async throws {
        let tmp = try await repoWithCommit()
        await #expect(throws: GitError.self) { try await tmp.repository.deleteBranch("main", force: true) }
    }

    // MARK: Upstreams

    @Test func remoteBranchBecomesATrackingLocalBranch() async throws {
        let pair = try await TemporaryRemotePair()
        try await pair.local.repository.createBranch("feature")
        try await pair.local.commit("f", files: ["f.txt": "f"])
        try await pair.local.repository.push()
        try await pair.local.repository.switchBranch(to: "main")
        try await pair.local.repository.deleteBranch("feature", force: true)

        try await pair.local.repository.switchToRemoteBranch("origin/feature")
        #expect(try await pair.local.repository.currentBranch() == "feature")
        let feature = try await pair.local.repository.localBranches().first { $0.shortName == "feature" }
        #expect(feature?.upstream == "refs/remotes/origin/feature")
    }

    @Test func switchingToARemoteBranchWithALocalCopyJustSwitches() async throws {
        let pair = try await TemporaryRemotePair()
        try await pair.local.repository.createBranch("feature")
        try await pair.local.repository.push()
        try await pair.local.repository.switchBranch(to: "main")
        try await pair.local.repository.switchToRemoteBranch("origin/feature")
        #expect(try await pair.local.repository.currentBranch() == "feature")
    }

    @Test func setsAndUnsetsUpstream() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        try await repo.createBranch("topic", checkout: false)
        try await repo.setUpstream(of: "main", to: "origin/main")
        try await repo.unsetUpstream(of: "main")
        #expect(try await repo.localBranches().first { $0.shortName == "main" }?.upstream == nil)
        try await repo.setUpstream(of: "main", to: "origin/main")
        #expect(try await repo.localBranches().first { $0.shortName == "main" }?.upstream == "refs/remotes/origin/main")
    }

    @Test func aheadAndBehindCountsFollowPushAndFetch() async throws {
        let pair = try await TemporaryRemotePair()
        let repo = pair.local.repository
        try await pair.local.commit("local 1", files: ["l1.txt": "1"])
        try await pair.local.commit("local 2", files: ["l2.txt": "2"])
        var main = try await repo.localBranches().first { $0.shortName == "main" }
        #expect(main?.ahead == 2)
        #expect(main?.behind == 0)

        let mate = try await pair.makeTeammate()
        try await mate.commit("remote 1", files: ["r1.txt": "1"])
        try await mate.git("push", "origin", "main")
        try await repo.fetch()
        main = try await repo.localBranches().first { $0.shortName == "main" }
        #expect(main?.ahead == 2)
        #expect(main?.behind == 1)
        let status = try await repo.status()
        #expect(status.branch.ahead == 2)
        #expect(status.branch.behind == 1)
    }
}
