import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

@Suite("Repository against real sample repos")
struct RepositoryTests {
    // MARK: Opening

    @Test func opensFromASubfolderAndFindsTheRoot() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("init", files: ["deep/nested/file.txt": "x"])
        let opened = try await Repository.open(at: tmp.url.appendingPathComponent("deep/nested"), git: tmp.git)
        #expect(opened.rootURL.standardizedFileURL.path == tmp.url.standardizedFileURL.path)
        #expect(opened == tmp.repository)
    }

    @Test func openingAPlainFolderThrowsNotARepository() async throws {
        let tmp = try await TemporaryRepository()
        let outside = tmp.baseURL.appendingPathComponent("home")
        await #expect(throws: GitError.notARepository(outside)) { try await Repository.open(at: outside, git: tmp.git) }
    }

    @Test func openingABareRepositoryThrows() async throws {
        let bare = try await TemporaryRepository(bare: true)
        await #expect(throws: GitError.self) { try await Repository.open(at: bare.url, git: bare.git) }
    }

    @Test func initializeUsesTheRequestedBranch() async throws {
        let tmp = try await TemporaryRepository(initialBranch: "trunk")
        let status = try await tmp.repository.status()
        #expect(status.branch.branch == "trunk")
        #expect(status.branch.isUnborn)
        #expect(try await tmp.repository.currentBranch() == "trunk")
    }

    // MARK: Status

    @Test func statusCoversEveryKindOfChange() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("init", files: ["keep.txt": "1\n", "edit.txt": "1\n", "remove.txt": "1\n", "move.txt": "a\nb\nc\nd\n"])
        let repo = tmp.repository

        try tmp.write("edit.txt", "2\n")                      // unstaged modification
        try tmp.write("staged.txt", "new\n")                  // staged addition
        try await tmp.git("add", "staged.txt")
        try tmp.delete("remove.txt")                          // unstaged deletion
        try await tmp.git("mv", "move.txt", "moved here.txt") // staged rename with a space
        try tmp.write("café/ünïcode.txt", "u\n")              // untracked, non-ASCII path
        try tmp.write(".gitignore", "*.log\n")
        try tmp.write("debug.log", "ignored\n")

        let status = try await repo.status(includeIgnored: true)
        let byPath = Dictionary(uniqueKeysWithValues: status.entries.map { ($0.path, $0) })

        #expect(byPath["edit.txt"]?.workTree == .modified)
        #expect(byPath["staged.txt"]?.index == .added)
        #expect(byPath["remove.txt"]?.workTree == .deleted)
        #expect(byPath["moved here.txt"]?.kind == .renamed(similarity: 100))
        #expect(byPath["moved here.txt"]?.originalPath == "move.txt")
        #expect(byPath["café/ünïcode.txt"]?.kind == .untracked)
        #expect(byPath["debug.log"]?.kind == .ignored)
        #expect(byPath["keep.txt"] == nil)
        #expect(Set(status.staged.map(\.path)) == ["staged.txt", "moved here.txt"])
        #expect(!status.isClean)

        let withoutUntracked = try await repo.status(includeUntracked: false)
        #expect(!withoutUntracked.entries.contains { $0.kind == .untracked || $0.kind == .ignored })
    }

    @Test func statusReportsDetachedHeadAndStashes() async throws {
        let tmp = try await TemporaryRepository()
        let first = try await tmp.commit("one", files: ["f": "1"])
        try await tmp.commit("two", files: ["f": "2"])
        try tmp.write("f", "dirty")
        try await tmp.git("stash", "push", "--quiet")
        try await tmp.git("checkout", "--quiet", "--detach", first)

        let status = try await tmp.repository.status()
        #expect(status.branch.isDetached)
        #expect(status.branch.headOID == first)
        #expect(status.stashCount == 1)
        #expect(status.isClean)
        #expect(try await tmp.repository.currentBranch() == nil)
    }

    @Test func statusReportsConflicts() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("base", files: ["c.txt": "base\n"])
        try await tmp.git("switch", "--quiet", "-c", "other")
        try await tmp.commit("theirs", files: ["c.txt": "theirs\n"])
        try await tmp.git("switch", "--quiet", "main")
        try await tmp.commit("ours", files: ["c.txt": "ours\n"])
        let merge = try await tmp.git.run(["merge", "other"], in: tmp.url)
        #expect(!merge.succeeded)

        let status = try await tmp.repository.status()
        #expect(status.conflicted.map(\.path) == ["c.txt"])
        #expect(status.conflicted.first?.kind == .unmerged(.bothModified))
    }

    @Test func statusAndRefsTrackTheUpstream() async throws {
        let remote = try await TemporaryRepository(bare: true)
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["f": "1"])
        try await tmp.git("remote", "add", "origin", remote.url.path)
        try await tmp.git("push", "--quiet", "-u", "origin", "main")
        try await tmp.commit("two", files: ["f": "2"])
        try await tmp.commit("three", files: ["f": "3"])

        let status = try await tmp.repository.status()
        #expect(status.branch.upstream == "origin/main")
        #expect(status.branch.ahead == 2)
        #expect(status.branch.behind == 0)

        let refs = try await tmp.repository.refs()
        let main = try #require(refs.first { $0.name == "refs/heads/main" })
        #expect(main.upstream == "refs/remotes/origin/main")
        #expect(main.ahead == 2 && main.behind == 0)
        #expect(main.isHead)
        #expect(refs.contains { $0.kind == .remoteBranch(remote: "origin") && $0.shortName == "origin/main" })
    }

    // MARK: History

    @Test func logReturnsCommitsNewestFirstWithFullDetails() async throws {
        let tmp = try await TemporaryRepository()
        let firstTime = tmp.nextCommitTime
        let first = try await tmp.commit("First commit\n\nWith a body\nover two lines.\n", files: ["a": "1"])
        let second = try await tmp.commit("Second: ünïcode ✓", files: ["b": "1"])
        try await tmp.git("tag", "-a", "v1.0", "-m", "release")

        let log = try await tmp.repository.log()
        #expect(log.map(\.id) == [second, first])
        #expect(log[1].summary == "First commit")
        #expect(log[1].body == "With a body\nover two lines.")
        #expect(log[1].parents.isEmpty)
        #expect(log[0].parents == [first])
        #expect(log[0].summary == "Second: ünïcode ✓")
        #expect(log[1].author == Signature(name: "Test Author", email: "author@example.com",
                                            date: Date(timeIntervalSince1970: TimeInterval(firstTime))))
        #expect(log[1].committer.name == "Test Committer")
        #expect(log[0].decorations.contains(Decoration(kind: .localBranch, fullName: "refs/heads/main", isHead: true)))
        #expect(log[0].decorations.contains(Decoration(kind: .tag, fullName: "refs/tags/v1.0")))
    }

    @Test func logTellsLocalBranchesWithSlashesFromRemoteBranches() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("c1", files: ["a": "1"])
        try await tmp.git("branch", "feature/x")
        try await tmp.git("update-ref", "refs/remotes/origin/main", "HEAD")
        let decorations = try await tmp.repository.log()[0].decorations
        #expect(decorations.first { $0.name == "feature/x" }?.kind == .localBranch)
        #expect(decorations.first { $0.name == "origin/main" }?.kind == .remoteBranch)
        #expect(decorations.first { $0.isHead }?.name == "main")
    }

    @Test func logSupportsLimitsPathsRevisionsAndMerges() async throws {
        let tmp = try await TemporaryRepository()
        let c1 = try await tmp.commit("c1", files: ["a.txt": "1"])
        let c2 = try await tmp.commit("c2", files: ["b.txt": "1"])
        try await tmp.git("switch", "--quiet", "-c", "topic")
        let t1 = try await tmp.commit("t1", files: ["a.txt": "2"])
        try await tmp.git("switch", "--quiet", "main")
        let c3 = try await tmp.commit("c3", files: ["c.txt": "1"])
        try await tmp.git("merge", "--quiet", "--no-ff", "-m", "merge topic", "topic")
        let repo = tmp.repository

        let all = try await repo.log()
        #expect(all.count == 5)
        #expect(all[0].isMerge && all[0].parents == [c3, t1])

        #expect(try await repo.log(LogQuery(limit: 2)).count == 2)
        #expect(try await repo.log(LogQuery(limit: 2, skip: 3)).map(\.id) == [c2, c1])
        #expect(try await repo.log(LogQuery(paths: ["a.txt"])).map(\.id) == [t1, c1])
        #expect(try await repo.log(LogQuery(revisions: ["topic"])).map(\.id) == [t1, c2, c1])
        #expect(try await repo.log(LogQuery(revisions: ["main..topic"])).isEmpty)
        #expect(try await repo.log(LogQuery(revisions: ["topic..main"])).count == 2)
        #expect(try await repo.log(LogQuery(allRefs: true, topologicalOrder: true)).count == 5)
        #expect(try await repo.commit("topic").id == t1)
    }

    @Test func logOfAnEmptyRepositoryIsEmpty() async throws {
        let tmp = try await TemporaryRepository()
        #expect(try await tmp.repository.log().isEmpty)
        #expect(try await tmp.repository.resolve("HEAD") == nil)
    }

    @Test func optionLikeRevisionsAreNotTreatedAsOptions() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["f": "1"])
        #expect(try await tmp.repository.resolve("--all") == nil)
        await #expect(throws: GitError.self) { try await tmp.repository.log(LogQuery(revisions: ["--output=/tmp/pwned"])) }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    // MARK: Refs, remotes, config

    @Test func refsListBranchesAndTags() async throws {
        let tmp = try await TemporaryRepository()
        let head = try await tmp.commit("one", files: ["f": "1"])
        try await tmp.git("branch", "feature/login")
        try await tmp.git("tag", "light")
        try await tmp.git("tag", "-a", "annotated", "-m", "note")

        let refs = try await tmp.repository.refs()
        #expect(refs.map(\.shortName) == ["feature/login", "main", "annotated", "light"])
        let annotated = try #require(refs.first { $0.shortName == "annotated" })
        #expect(annotated.kind == .tag)
        #expect(annotated.target != head)
        #expect(annotated.commitID == head)
        #expect(refs.first { $0.shortName == "light" }?.commitID == head)
        #expect(try await tmp.repository.localBranches().map(\.shortName) == ["feature/login", "main"])
    }

    @Test func remotesAndConfig() async throws {
        let tmp = try await TemporaryRepository()
        let repo = tmp.repository
        #expect(try await repo.remotes().isEmpty)
        try await tmp.git("remote", "add", "origin", "https://github.com/example/repo.git")
        try await tmp.git("remote", "add", "fork.mine", "git@gitlab.com:me/repo.git")
        try await tmp.git("remote", "set-url", "--push", "origin", "git@github.com:example/repo.git")

        let remotes = try await repo.remotes()
        #expect(remotes.map(\.name) == ["origin", "fork.mine"])
        #expect(remotes[0].fetchURL == "https://github.com/example/repo.git")
        #expect(remotes[0].effectivePushURL == "git@github.com:example/repo.git")

        #expect(try await repo.config("user.name") == nil)
        try await repo.setConfig("user.name", to: "Someone Else")
        #expect(try await repo.config("user.name") == "Someone Else")
    }

    // MARK: Diff

    @Test func diffsWorkTreeStagedCommitAndRange() async throws {
        let tmp = try await TemporaryRepository()
        let repo = tmp.repository
        try tmp.write("notes.txt", "one\n")
        let unbornStaged = try await { try await repo.stage(["notes.txt"]); return try await repo.diff(.staged) }()
        #expect(unbornStaged.first?.change == .added)

        let c1 = try await tmp.commit("one", files: ["notes.txt": "one\ntwo\nthree\n"])
        let c2 = try await tmp.commit("two", files: ["notes.txt": "one\n2\nthree\n", "data.bin": "\u{0}\u{1}\u{2}"])
        try tmp.write("notes.txt", "one\n2\nthree\nfour\n")
        try tmp.write("staged.txt", "s\n")
        try await repo.stage(["staged.txt"])

        let workTree = try await repo.diff()
        #expect(workTree.map(\.path) == ["notes.txt"])
        #expect(workTree[0].hunks[0].lines.last == DiffLine(kind: .addition, text: "four", newLineNumber: 4))

        let staged = try await repo.diff(.staged)
        #expect(staged.map(\.path) == ["staged.txt"])
        #expect(staged[0].change == .added)

        let commit = try await repo.diff(.commit(c2))
        #expect(Set(commit.map(\.path)) == ["notes.txt", "data.bin"])
        #expect(commit.first { $0.path == "data.bin" }?.isBinary == true)
        #expect(commit.first { $0.path == "notes.txt" }.map { ($0.additions, $0.deletions) }! == (1, 1))

        let range = try await repo.diff(.range(from: c1, to: c2), paths: ["notes.txt"], contextLines: 0)
        #expect(range.count == 1)
        #expect(range[0].hunks[0].lines.map(\.kind) == [.deletion, .addition])
    }

    @Test func diffDetectsRenames() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["old name.txt": "alpha\nbeta\ngamma\ndelta\n"])
        try await tmp.git("mv", "old name.txt", "new name.txt")
        let staged = try await tmp.repository.diff(.staged)
        #expect(staged.count == 1)
        #expect(staged[0].change == .renamed(similarity: 100))
        #expect(staged[0].oldPath == "old name.txt" && staged[0].newPath == "new name.txt")
    }

    // MARK: Staging and committing

    @Test func stageUnstageAndCommit() async throws {
        let tmp = try await TemporaryRepository()
        let repo = tmp.repository
        try tmp.write("a.txt", "a\n")
        try tmp.write("b.txt", "b\n")

        try await repo.stage(["a.txt"])
        #expect(try await repo.status().staged.map(\.path) == ["a.txt"])
        try await repo.unstage(["a.txt"]) // unborn HEAD path
        #expect(try await repo.status().staged.isEmpty)

        try await repo.stageAll()
        let first = try await repo.commit(message: "Add files\n\nBody text\n")
        #expect(try await repo.status().isClean)
        let head = try await repo.commit("HEAD")
        #expect(head.id == first && head.summary == "Add files" && head.body == "Body text")

        try tmp.write("a.txt", "changed\n")
        try tmp.delete("b.txt")
        try await repo.stage(["a.txt", "b.txt"])
        #expect(Set(try await repo.status().staged.map(\.path)) == ["a.txt", "b.txt"])
        try await repo.unstage(["b.txt"]) // born HEAD path
        #expect(try await repo.status().staged.map(\.path) == ["a.txt"])

        try await repo.stage([])
        try await repo.unstage([])
        let second = try await repo.commit(message: "Change a")
        let amended = try await repo.commit(message: "Change a, reworded", amend: true)
        #expect(amended != second)
        #expect(try await repo.log().map(\.summary) == ["Change a, reworded", "Add files"])

        await #expect(throws: GitError.self) { try await repo.commit(message: "nothing staged") }
        let empty = try await repo.commit(message: "Empty", allowEmpty: true)
        #expect(try await repo.commit("HEAD").id == empty)
    }

    @Test func runThrowsCommandFailedWithStderr() async throws {
        let tmp = try await TemporaryRepository()
        do {
            try await tmp.repository.run(["checkout", "no-such-branch"])
            Issue.record("expected failure")
        } catch let GitError.commandFailed(arguments, exitCode, stderr) {
            #expect(arguments == ["checkout", "no-such-branch"])
            #expect(exitCode != 0)
            #expect(stderr.contains("no-such-branch"))
        }
    }

    @Test func fixtureHelpersReadAndWrite() async throws {
        let tmp = try await TemporaryRepository()
        try tmp.write("x/y.txt", "hello")
        #expect(try tmp.read("x/y.txt") == "hello")
        #expect(tmp.path == tmp.url.path)
        let base = tmp.baseURL
        _ = consume tmp
        #expect(!FileManager.default.fileExists(atPath: base.path), "the fixture deletes itself")
    }
}
