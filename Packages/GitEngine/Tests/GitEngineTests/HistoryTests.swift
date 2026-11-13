import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

@Suite("History, blame and search against real sample repos")
struct HistoryTests {
    /// main: add → rename → edit, with a side branch merged in, and a stash.
    private func sampleRepository() async throws -> TemporaryRepository {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("Add the readme", files: ["old name.txt": "one\ntwo\nthree\n", "src/App.swift": "app\n"])
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try await tmp.git("mv", "old name.txt", "notes/new name.txt")
        try await tmp.commit("Rename the readme")
        try await tmp.git("switch", "--quiet", "-c", "side")
        try await tmp.commit("Fix(ui): side work", files: ["src/SideView.swift": "side\n"])
        try await tmp.git("switch", "--quiet", "main")
        try await tmp.commit("Edit the readme", files: ["notes/new name.txt": "one\nTWO\nthree\nfour\n"])
        try await tmp.git("merge", "--quiet", "--no-ff", "-m", "Merge side", "side")
        return tmp
    }

    // MARK: Commit files

    @Test func changedFilesCoversRootRenameAndMergeCommits() async throws {
        let tmp = try await sampleRepository()
        let repo = tmp.repository
        let commits = try await repo.log(LogQuery(topologicalOrder: true))
        let byTitle = Dictionary(uniqueKeysWithValues: commits.map { ($0.summary, $0) })

        let root = try #require(byTitle["Add the readme"])
        #expect(try await repo.changedFiles(in: root) == [
            CommitFileChange(change: .added, path: "old name.txt"),
            CommitFileChange(change: .added, path: "src/App.swift"),
        ])

        let rename = try #require(byTitle["Rename the readme"])
        #expect(try await repo.changedFiles(in: rename) == [
            CommitFileChange(change: .renamed(similarity: 100), path: "notes/new name.txt", oldPath: "old name.txt"),
        ])

        // A merge lists what it brought in compared with its first parent.
        let merge = try #require(byTitle["Merge side"])
        #expect(try await repo.changedFiles(in: merge) == [CommitFileChange(change: .added, path: "src/SideView.swift")])
    }

    @Test func diffOfOneFileInACommitPairsRenames() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("add", files: ["a.txt": "1\n2\n3\n4\n5\n6\n"])
        try await tmp.git("mv", "a.txt", "b.txt")
        try tmp.write("b.txt", "1\n2\n3\n4\n5\nsix\n")
        try await tmp.commit("rename and edit")
        let repo = tmp.repository
        let head = try await repo.commit("HEAD")
        let change = try #require(try await repo.changedFiles(in: head).first)
        #expect(change.oldPath == "a.txt")
        let diff = try #require(try await repo.diff(of: change, in: head))
        #expect(diff.oldPath == "a.txt")
        #expect(diff.newPath == "b.txt")
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)

        let root = try await repo.commit("HEAD~1")
        let added = try #require(try await repo.diff(of: CommitFileChange(change: .added, path: "a.txt"), in: root))
        #expect(added.change == .added)
        #expect(added.additions == 6)
    }

    // MARK: File history

    @Test func fileHistoryFollowsRenames() async throws {
        let tmp = try await sampleRepository()
        let history = try await tmp.repository.fileHistory(of: "notes/new name.txt")
        #expect(history.map(\.commit.summary) == ["Edit the readme", "Rename the readme", "Add the readme"])
        #expect(history.map(\.path) == ["notes/new name.txt", "notes/new name.txt", "old name.txt"])
        #expect(history[1].change?.oldPath == "old name.txt")
        #expect(history[2].change?.change == .added)

        let limited = try await tmp.repository.fileHistory(of: "notes/new name.txt", limit: 1)
        #expect(limited.count == 1)
        let fromSide = try await tmp.repository.fileHistory(of: "src/SideView.swift", from: "side")
        #expect(fromSide.map(\.commit.summary) == ["Fix(ui): side work"])
    }

    @Test func fileHistoryIsEmptyBeforeTheFirstCommit() async throws {
        let tmp = try await TemporaryRepository()
        #expect(try await tmp.repository.fileHistory(of: "x").isEmpty)
    }

    @Test func fileHistoryEntriesCanBeDiffed() async throws {
        let tmp = try await sampleRepository()
        let repo = tmp.repository
        let history = try await repo.fileHistory(of: "notes/new name.txt")
        let edit = history[0]
        let change = try #require(edit.change)
        let diff = try #require(try await repo.diff(of: change, in: edit.commit))
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
    }

    // MARK: Blame

    @Test func blameShowsWhoChangedEachLineAcrossARename() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.git("commit", "--quiet", "--allow-empty", "-m", "start")
        try tmp.write("old.txt", "one\ntwo\nthree\n")
        try await tmp.git("add", "old.txt")
        try await tmp.git("commit", "--quiet", "-m", "Ann's lines", "--author=Ann Lee <ann@example.com>")
        try await tmp.git("mv", "old.txt", "new file.txt")
        try await tmp.commit("rename")
        try tmp.write("new file.txt", "one\nTWO\nthree\n")
        try await tmp.git("commit", "--quiet", "-am", "Bob's edit", "--author=Bob <bob@example.com>")

        let repo = tmp.repository
        let blame = try await repo.blame("new file.txt", at: "HEAD")
        #expect(blame.lines.map(\.text) == ["one", "TWO", "three"])
        #expect(blame.lines.map { blame.commit(for: $0)?.author.name } == ["Ann Lee", "Bob", "Ann Lee"])
        #expect(blame.lines[0].originalPath == "old.txt", "blame follows the line back through the rename")
        #expect(blame.lines.map(\.lineNumber) == [1, 2, 3])
        #expect(blame.commit(for: blame.lines[1])?.summary == "Bob's edit")
        #expect(blame.groups.count == 3)

        // An older revision.
        let before = try await repo.blame("new file.txt", at: "HEAD~1")
        #expect(before.lines.map(\.text) == ["one", "two", "three"])
        #expect(Set(before.lines.map(\.commitID)).count == 1)
    }

    @Test func blameOfTheWorkTreeMarksUncommittedLines() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("add", files: ["f.txt": "a\nb\n"])
        try tmp.write("f.txt", "a\nchanged\n")
        let blame = try await tmp.repository.blame("f.txt")
        #expect(blame.commit(for: blame.lines[0])?.isUncommitted == false)
        #expect(blame.commit(for: blame.lines[1])?.isUncommitted == true)
    }

    @Test func blameOfAMissingFileThrows() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("add", files: ["f.txt": "a\n"])
        await #expect(throws: GitError.self) { try await tmp.repository.blame("nope.txt", at: "HEAD") }
        await #expect(throws: GitError.self) { try await tmp.repository.blame("f.txt", at: "--output=/tmp/stronghold-x") }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/stronghold-x"))
    }

    // MARK: Search

    @Test func searchesMessagesAsPlainTextIgnoringCase() async throws {
        let tmp = try await sampleRepository()
        let repo = tmp.repository
        let found = try await repo.log(LogQuery(allRefs: true, messagePattern: "fix(UI)"))
        #expect(found.map(\.summary) == ["Fix(ui): side work"])
        let readme = try await repo.log(LogQuery(messagePattern: "README"))
        #expect(readme.map(\.summary) == ["Edit the readme", "Rename the readme", "Add the readme"])
        #expect(try await repo.log(LogQuery(messagePattern: "--all")).isEmpty, "a pattern is never read as an option")
    }

    @Test func searchesByAuthorNameOrEmail() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("mine")
        try await tmp.git("commit", "--quiet", "--allow-empty", "-m", "theirs", "--author=Zoë Field <zoe@elsewhere.org>")
        let repo = tmp.repository
        #expect(try await repo.log(LogQuery(authorPattern: "zoë")).map(\.summary) == ["theirs"])
        #expect(try await repo.log(LogQuery(authorPattern: "ELSEWHERE.org")).map(\.summary) == ["theirs"])
        #expect(try await repo.log(LogQuery(authorPattern: "test author")).map(\.summary) == ["mine"])
    }

    @Test func searchesForCommitsThatAddOrRemoveText() async throws {
        let tmp = try await sampleRepository()
        let found = try await tmp.repository.log(LogQuery(contentPattern: "TWO"))
        #expect(found.map(\.summary) == ["Edit the readme"])
    }

    @Test func searchesByFileName() async throws {
        let tmp = try await sampleRepository()
        let repo = tmp.repository
        let views = try await repo.log(LogQuery(allRefs: true, paths: LogQuery.pathsContaining("sideview")))
        #expect(views.map(\.summary) == ["Fix(ui): side work"])
        let folder = try await repo.log(LogQuery(paths: LogQuery.pathsContaining("src")))
        #expect(folder.map(\.summary).contains("Add the readme"), "a folder name matches the files inside it")
        #expect(try await repo.log(LogQuery(paths: LogQuery.pathsContaining("*"))).isEmpty, "glob characters are literal")
    }

    @Test func allRefsWalksEveryBranchButNotStashes() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("base", files: ["f": "1\n"])
        try await tmp.git("switch", "--quiet", "-c", "other")
        try await tmp.commit("on other")
        try await tmp.git("switch", "--quiet", "main")
        try tmp.write("f", "2\n")
        try await tmp.git("stash", "push", "--quiet", "-m", "parked")
        let repo = tmp.repository
        let all = try await repo.log(LogQuery(allRefs: true, topologicalOrder: true))
        #expect(all.map(\.summary) == ["on other", "base"])
        #expect(try await repo.log().map(\.summary) == ["base"])
    }

    @Test func historyGraphOfARealRepository() async throws {
        let tmp = try await sampleRepository()
        let commits = try await tmp.repository.log(LogQuery(allRefs: true, topologicalOrder: true))
        let graph = CommitGraph(commits)
        #expect(graph.rows.count == 5)
        #expect(graph.width == 2)
        #expect(graph.rows[0].isMerge)
        #expect(graph.rows.last?.bottom.isEmpty == true)
    }
}
