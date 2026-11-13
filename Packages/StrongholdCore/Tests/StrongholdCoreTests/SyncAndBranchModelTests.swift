import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

@MainActor private var keepPairs: [TemporaryRemotePair] = []
@MainActor private var keepModels: [RepositoryModel] = []
@MainActor private var keepRepos: [TemporaryRepository] = []

@MainActor
@Suite("Sync and branch models")
struct SyncAndBranchModelTests {
    private func setUp() async throws -> (TemporaryRemotePair, RepositoryModel) {
        let pair = try await TemporaryRemotePair()
        let model = RepositoryModel(repository: pair.local.repository)
        keepPairs.append(pair)
        keepModels.append(model)
        await model.refresh()
        return (pair, model)
    }

    // MARK: Sync

    @Test func fetchUpdatesBehindCountsAndReportsNothingWrong() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        #expect(model.currentBehind == 0)

        await model.sync.fetch()
        #expect(model.currentBehind == 1)
        #expect(model.sync.failure == nil)
        #expect(!model.sync.isBusy)
        #expect(model.trackingDescription == "1 behind origin/main")
    }

    @Test func pullThenPushRoundTrip() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["o.txt": "o"])
        await model.refresh()

        await model.sync.pull(strategy: .rebase)
        #expect(model.sync.failure == nil)
        #expect(model.currentBehind == 0)
        #expect(model.currentAhead == 1)
        #expect(model.canPush)

        await model.sync.push()
        #expect(model.sync.failure == nil)
        #expect(model.currentAhead == 0)
        #expect(!model.canPush)
        #expect(model.sync.notice == "Pushed to origin.")
    }

    @Test func pullFollowsTheConfiguredStrategyByDefault() async throws {
        let (pair, model) = try await setUp()
        try await model.repository.setConfig("pull.rebase", to: "true")
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["o.txt": "o"])
        await model.sync.pull()
        #expect(model.commits.map(\.summary) == ["ours", "theirs", "first"])
    }

    @Test func alreadyUpToDateIsANoticeNotAnError() async throws {
        let (_, model) = try await setUp()
        await model.sync.pull()
        #expect(model.sync.notice == "Already up to date.")
        #expect(model.sync.failure == nil)
    }

    @Test func rejectedPushBecomesAReadableFailure() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["t.txt": "t"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["o.txt": "o"])
        await model.refresh()
        await model.sync.push()
        let failure = try #require(model.sync.failure)
        #expect(failure.reason == .pushRejectedNonFastForward)
        #expect(failure.title == "Push failed")
        #expect(failure.message.contains("Pull first"))
        #expect(failure.retry == nil)
        model.sync.dismissFailure()
        #expect(model.sync.failure == nil)
    }

    @Test func localChangesInTheWayOffersAnAutostashRetry() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["a.txt": "theirs\n"])
        try await mate.git("push", "origin", "main")
        try pair.local.write("a.txt", "dirty\n")
        await model.sync.pull(strategy: .merge)
        let failure = try #require(model.sync.failure)
        #expect(failure.reason == .localChangesInTheWay)
        #expect(failure.retry == .pullWithAutostash)

        await model.sync.retry(.pullWithAutostash)
        #expect(model.sync.failure == nil)
        #expect(model.currentBehind == 0)
        // The autostash reapplies onto a conflicting change, so the file ends up conflicted or restored,
        // but the pull itself went through.
        #expect(model.commits.first?.summary == "theirs")
    }

    @Test func conflictingPullFailsAndTheConflictShowsInTheWorkingCopy() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.commit("theirs", files: ["a.txt": "theirs\n"])
        try await mate.git("push", "origin", "main")
        try await pair.local.commit("ours", files: ["a.txt": "ours\n"])
        await model.refresh()
        await model.sync.pull(strategy: .merge)
        #expect(model.sync.failure?.reason == .mergeConflict)
        #expect(model.workingCopy.conflicted.map(\.path) == ["a.txt"])
    }

    @Test func operationsDontOverlap() async throws {
        let (_, model) = try await setUp()
        async let first: Void = model.sync.fetch()
        async let second: Void = model.sync.fetch()
        _ = await (first, second)
        #expect(!model.sync.isBusy)
    }

    @Test func activityTextShowsProgress() {
        var activity = SyncModel.Activity(kind: .push)
        #expect(activity.text == "Pushing\u{2026}")
        activity.progress = TransferProgress(phase: "Writing objects", percent: 40, current: 4, total: 10)
        #expect(activity.text == "Pushing \u{00B7} Writing objects 40%")
    }

    @Test func failureWithoutARemoteExplainsWhatToDo() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("x")
        let model = RepositoryModel(repository: tmp.repository)
        keepModels.append(model)
        keepRepos.append(tmp)
        await model.refresh()
        #expect(!model.hasRemote)
        #expect(!model.canPush)
        await model.sync.fetch()
        #expect(model.sync.failure?.reason == .noRemote)
        #expect(model.sync.failure?.message.contains("no remote") == true)
    }

    // MARK: Branches

    @Test func createSwitchRenameAndDeleteThroughTheModel() async throws {
        let (_, model) = try await setUp()
        #expect(await model.createBranch("feature"))
        #expect(model.headDescription == "feature")
        #expect(model.localBranches.map(\.shortName).sorted() == ["feature", "main"])

        let main = try #require(model.localBranches.first { $0.shortName == "main" })
        await model.switchTo(main)
        #expect(model.headDescription == "main")

        #expect(await model.renameBranch("feature", to: "feature-2"))
        #expect(model.localBranches.map(\.shortName).sorted() == ["feature-2", "main"])

        let result = await model.deleteBranch("feature-2")
        guard case .deleted(let tip) = result else { Issue.record("expected a deletion, got \(result)"); return }
        #expect(tip != nil)
        #expect(model.actionNotice?.contains("Deleted branch feature-2") == true)
        #expect(model.localBranches.map(\.shortName) == ["main"])
    }

    @Test func invalidNameSetsAnActionError() async throws {
        let (_, model) = try await setUp()
        #expect(await model.createBranch("not valid") == false)
        #expect(model.actionError?.contains("isn\u{2019}t a valid branch name") == true)
        model.dismissActionError()
        #expect(model.actionError == nil)
    }

    @Test func deletingAnUnmergedBranchAsksForForce() async throws {
        let (pair, model) = try await setUp()
        _ = await model.createBranch("wip")
        try await pair.local.commit("wip", files: ["w.txt": "w"])
        await model.switchTo(try #require(model.localBranches.first { $0.shortName == "main" }))

        #expect(await model.deleteBranch("wip") == .needsForce)
        #expect(model.actionError == nil)
        #expect(model.localBranches.count == 2)
        guard case .deleted = await model.deleteBranch("wip", force: true) else { Issue.record("force delete failed"); return }
        #expect(model.localBranches.count == 1)
    }

    @Test func deletingTheCurrentBranchIsReported() async throws {
        let (_, model) = try await setUp()
        #expect(await model.deleteBranch("main", force: true) == .failed)
        #expect(model.actionError != nil)
    }

    @Test func switchingToARemoteBranchCreatesATrackingBranch() async throws {
        let (pair, model) = try await setUp()
        let mate = try await pair.makeTeammate()
        try await mate.git("push", "origin", "main:refs/heads/shared")
        await model.sync.fetch()
        let remote = try #require(model.remoteBranches.first?.branches.first { $0.shortName == "origin/shared" })
        await model.switchTo(remote)
        #expect(model.headDescription == "shared")
        #expect(model.trackingDescription == "Up to date with origin/shared")
    }

    @Test func switchingToATagDetachesHead() async throws {
        let (pair, model) = try await setUp()
        try await pair.local.git("tag", "v1")
        await model.refresh()
        await model.switchTo(try #require(model.tags.first))
        #expect(model.headDescription.hasPrefix("Detached at"))
    }

    @Test func switchFailureLeavesTheBranchAndShowsTheReason() async throws {
        let (pair, model) = try await setUp()
        _ = await model.createBranch("other")
        try await pair.local.commit("change", files: ["a.txt": "other\n"])
        await model.switchTo(try #require(model.localBranches.first { $0.shortName == "main" }))
        try pair.local.write("a.txt", "dirty\n")
        await model.switchTo(try #require(model.localBranches.first { $0.shortName == "other" }))
        #expect(model.headDescription == "main")
        #expect(model.actionError?.contains("overwritten") == true)
    }

    @Test func setAndClearUpstream() async throws {
        let (_, model) = try await setUp()
        await model.setUpstream(of: "main", to: nil)
        #expect(!model.hasUpstream)
        #expect(model.upstreamCandidates == ["origin/main"])
        await model.setUpstream(of: "main", to: "origin/main")
        #expect(model.hasUpstream)
    }

    @Test func firstPushOfANewBranchIsAllowedThenDisabledWhenInSync() async throws {
        let (_, model) = try await setUp()
        _ = await model.createBranch("fresh")
        #expect(model.canPush) // not published yet
        await model.sync.push()
        #expect(model.sync.notice == "Published fresh to origin.")
        #expect(model.hasUpstream)
        #expect(!model.canPush)
    }
}
