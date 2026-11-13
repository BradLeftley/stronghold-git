import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
@Suite("App and repository models")
struct StrongholdCoreTests {
    private func appModel(for tmp: TemporaryRepository, beeps: Counter = Counter()) -> AppModel {
        let git = tmp.git
        return AppModel(library: RepositoryLibrary(storageURL: nil), feedback: Feedback(environment: [:], play: { beeps.increment() }), locate: { git })
    }

    @Test func startFindsASupportedGit() async throws {
        let tmp = try await TemporaryRepository()
        let model = appModel(for: tmp)
        #expect(model.gitState == .checking)
        await model.start()
        guard case .ready(let version) = model.gitState else { Issue.record("git not ready: \(model.gitState)"); return }
        #expect(version >= GitVersion.minimumSupported)
        #expect(model.git != nil)
    }

    @Test func startReportsMissingGit() async {
        let model = AppModel(library: RepositoryLibrary(storageURL: nil), feedback: Feedback(environment: [:], play: {}), locate: { nil })
        await model.start()
        #expect(model.gitState == .unavailable(GitError.gitNotFound.localizedDescription))
        #expect(await model.open(URL(fileURLWithPath: "/tmp")) == false)
        #expect(model.openError != nil)
    }

    @Test func startReportsABrokenGit() async {
        let broken = GitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false"), configOverrides: [:])
        let model = AppModel(library: RepositoryLibrary(storageURL: nil), feedback: Feedback(environment: [:], play: {}), locate: { broken })
        await model.start()
        guard case .unavailable = model.gitState else { Issue.record("expected unavailable"); return }
        #expect(model.git == nil)
    }

    @Test func openLoadsTheRepository() async throws {
        let remote = try await TemporaryRepository(bare: true)
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["a.txt": "1"])
        try await tmp.git("remote", "add", "origin", remote.url.path)
        try await tmp.git("push", "--quiet", "-u", "origin", "main")
        try await tmp.commit("two", files: ["a.txt": "2"])
        try await tmp.git("tag", "v1")
        try await tmp.git("branch", "feature")
        try tmp.write("new.txt", "n")

        let app = appModel(for: tmp)
        await app.start()
        #expect(await app.open(tmp.url))
        let repo = try #require(app.repository)
        #expect(repo.name == "repo")
        #expect(repo.id == tmp.url)
        #expect(repo.commits.map(\.summary) == ["two", "one"])
        #expect(repo.status.entries.map(\.path) == ["new.txt"])
        #expect(repo.localBranches.map(\.shortName) == ["feature", "main"])
        #expect(repo.tags.map(\.shortName) == ["v1"])
        #expect(repo.remoteBranches.map(\.remote) == ["origin"])
        #expect(repo.remoteBranches.first?.branches.map(\.shortName) == ["origin/main"])
        #expect(repo.remotes.map(\.name) == ["origin"])
        #expect(repo.headDescription == "main")
        #expect(repo.trackingDescription == "1 ahead origin/main")
        #expect(!repo.isLoading)
        #expect(repo.errorMessage == nil)

        app.close()
        #expect(app.repository == nil)
    }

    @Test func openingAFolderThatIsNotARepositoryOffersToInitialiseIt() async throws {
        let tmp = try await TemporaryRepository()
        let beeps = Counter()
        let app = appModel(for: tmp, beeps: beeps)
        await app.start()
        let folder = tmp.baseURL.appendingPathComponent("home")
        #expect(await app.open(folder) == false)
        #expect(app.offerToInitialize == folder)
        #expect(app.openError == nil)
        #expect(app.repository == nil)
        #expect(app.library.entries.isEmpty)
        #expect(beeps.count == 0)
    }

    @Test func scriptedRunsAreSilent() {
        let beeps = Counter()
        let feedback = Feedback(environment: ["ILLUMI_SCRIPTED": "1"], play: { beeps.increment() })
        feedback.error()
        #expect(feedback.isSilenced)
        #expect(beeps.count == 0)
        #expect(!Feedback.isSilenced(["ILLUMI_SCRIPTED": "0"]))
        #expect(!Feedback.isSilenced([:]))
    }

    @Test func headAndTrackingDescriptions() async throws {
        let tmp = try await TemporaryRepository()
        let repo = RepositoryModel(repository: tmp.repository, historyLimit: 1)
        await repo.refresh()
        #expect(repo.headDescription == "main")
        #expect(repo.commits.isEmpty)
        #expect(repo.trackingDescription == nil)

        let first = try await tmp.commit("one", files: ["a": "1"])
        try await tmp.commit("two", files: ["a": "2"])
        await repo.refresh()
        #expect(repo.commits.count == 1, "historyLimit is respected")

        try await tmp.git("checkout", "--quiet", "--detach", first)
        await repo.refresh()
        #expect(repo.headDescription == "Detached at \(first.prefix(7))")
    }

    @Test func trackingDescriptionCoversAllCases() async throws {
        let remote = try await TemporaryRepository(bare: true)
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["a": "1"])
        try await tmp.git("remote", "add", "origin", remote.url.path)
        try await tmp.git("push", "--quiet", "-u", "origin", "main")
        let repo = RepositoryModel(repository: tmp.repository)
        await repo.refresh()
        #expect(repo.trackingDescription == "Up to date with origin/main")

        try await tmp.git("reset", "--quiet", "--hard", "HEAD")
        try await tmp.commit("local", files: ["a": "2"])
        try await tmp.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try await tmp.git("reset", "--quiet", "--hard", "HEAD~1")
        try await tmp.commit("diverged", files: ["b": "1"])
        await repo.refresh()
        #expect(repo.trackingDescription == "1 ahead, 1 behind origin/main")
    }

    @Test func refreshReportsErrors() async throws {
        let tmp = try await TemporaryRepository()
        let missing = Repository(rootURL: tmp.baseURL.appendingPathComponent("gone"), git: tmp.git)
        let repo = RepositoryModel(repository: missing)
        await repo.refresh()
        #expect(repo.errorMessage != nil)
        #expect(repo.section == .changes)
    }

    @Test func badgesDescribeEachEntry() {
        let modifiedBoth = StatusEntry(kind: .ordinary, path: "m", index: .modified, workTree: .modified)
        #expect(modifiedBoth.stagedBadge == .modified && modifiedBoth.unstagedBadge == .modified)
        let added = StatusEntry(kind: .ordinary, path: "a", index: .added)
        #expect(added.badge == .added && added.unstagedBadge == nil)
        let deleted = StatusEntry(kind: .ordinary, path: "d", workTree: .deleted)
        #expect(deleted.badge == .deleted && deleted.stagedBadge == nil)
        let renamed = StatusEntry(kind: .renamed(similarity: 100), path: "r", originalPath: "o", index: .renamed)
        #expect(renamed.badge == .renamed)
        let renamedThenEdited = StatusEntry(kind: .renamed(similarity: 90), path: "r", index: .renamed, workTree: .modified)
        #expect(renamedThenEdited.unstagedBadge == .modified)
        #expect(StatusEntry(kind: .copied(similarity: 100), path: "c", index: .copied).badge == .copied)
        #expect(StatusEntry(kind: .ordinary, path: "t", index: .typeChanged).badge == .typeChanged)
        #expect(StatusEntry(kind: .untracked, path: "u").badge == .untracked)
        #expect(StatusEntry(kind: .untracked, path: "u").unstagedBadge == .untracked)
        #expect(StatusEntry(kind: .ignored, path: "i").badge == .ignored)
        #expect(StatusEntry(kind: .unmerged(.bothModified), path: "x", index: .unmerged, workTree: .unmerged).badge == .conflicted)
        let allBadges: [ChangeBadge] = [.added, .modified, .deleted, .renamed, .copied, .typeChanged, .untracked, .conflicted, .ignored]
        #expect(Set(allBadges.map(\.label)).count == allBadges.count)
    }
}
