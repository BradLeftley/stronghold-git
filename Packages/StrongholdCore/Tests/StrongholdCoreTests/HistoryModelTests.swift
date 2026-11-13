import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

@MainActor
@Suite("History model")
struct HistoryModelTests {
    /// main: init → rename → edit, plus a `side` branch that isn't merged.
    private func sample() async throws -> TemporaryRepository {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("Add notes", files: ["notes.txt": "one\ntwo\n", "src/App.swift": "app\n"])
        try await tmp.git("mv", "notes.txt", "readme.txt")
        try await tmp.commit("Rename notes")
        try await tmp.git("switch", "--quiet", "-c", "side")
        try await tmp.commit("Side work", files: ["src/Side.swift": "side\n"])
        try await tmp.git("switch", "--quiet", "main")
        try await tmp.git("commit", "--quiet", "--allow-empty", "-m", "Empty by Zoë", "--author=Zoë <zoe@example.org>")
        try await tmp.commit("Edit readme", files: ["readme.txt": "one\nTWO\n"])
        return tmp
    }

    @Test func loadsTheCurrentBranchWithAGraphAndSelectsTheNewestCommit() async throws {
        let tmp = try await sample()
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()
        #expect(model.hasLoaded)
        #expect(model.rows.map(\.commit.summary) == ["Edit readme", "Empty by Zoë", "Rename notes", "Add notes"])
        #expect(model.graph?.rows.count == 4)
        #expect(model.canLoadMore == false)
        #expect(model.selectedCommit?.summary == "Edit readme")
        #expect(model.changedFiles == [CommitFileChange(change: .modified, path: "readme.txt")])
        #expect(model.listDescription == "Current Branch · 4 commits")
    }

    @Test func allBranchesIncludesOtherBranches() async throws {
        let tmp = try await sample()
        let model = HistoryModel(repository: tmp.repository)
        await model.setScope(.allBranches)
        #expect(model.rows.count == 5)
        #expect(model.rows.contains { $0.commit.summary == "Side work" })
        #expect(model.graph?.width == 2)
        await model.setScope(.allBranches)
        #expect(model.scope == .allBranches)
    }

    @Test func pagesThroughLongHistories() async throws {
        let tmp = try await TemporaryRepository()
        for index in 1...7 { try await tmp.commit("c\(index)") }
        let model = HistoryModel(repository: tmp.repository, pageSize: 3)
        await model.reload()
        #expect(model.rows.map(\.commit.summary) == ["c7", "c6", "c5"])
        #expect(model.canLoadMore)
        #expect(model.listDescription == "Current Branch · 3+ commits")
        await model.loadMore()
        await model.loadMore()
        #expect(model.rows.map(\.commit.summary) == ["c7", "c6", "c5", "c4", "c3", "c2", "c1"])
        #expect(model.canLoadMore == false)
        #expect(model.graph?.rows.count == 7, "the graph covers every loaded page")
        await model.loadMore()
        #expect(model.rows.count == 7)
    }

    @Test func searchesEachField() async throws {
        let tmp = try await sample()
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()

        await model.search("RENAME", in: .message)
        #expect(model.isSearching)
        #expect(model.graph == nil, "search results aren't a connected history")
        #expect(model.rows.map(\.commit.summary) == ["Rename notes"])
        #expect(model.listDescription == "1 commit matching “RENAME”")

        await model.search("zoë", in: .author)
        #expect(model.rows.map(\.commit.summary) == ["Empty by Zoë"])

        await model.search("app.swift", in: .file)
        #expect(model.rows.map(\.commit.summary) == ["Add notes"])

        await model.search("TWO", in: .content)
        #expect(model.rows.map(\.commit.summary) == ["Edit readme"])

        await model.search("no such thing", in: .message)
        #expect(model.rows.isEmpty)
        #expect(model.selectedCommit == nil)

        await model.search("", in: .message)
        #expect(!model.isSearching)
        #expect(model.rows.count == 4)
        #expect(model.graph != nil)
    }

    @Test func searchQueriesUseTheRightGitOptions() async throws {
        let tmp = try await TemporaryRepository()
        let model = HistoryModel(repository: tmp.repository, pageSize: 10)
        let plain = model.makeQuery(skip: 20)
        #expect(plain.limit == 11)
        #expect(plain.skip == 20)
        #expect(plain.topologicalOrder)
        await model.search("  x  ", in: .content)
        let search = model.makeQuery(skip: 0)
        #expect(search.contentPattern == "x")
        #expect(search.topologicalOrder == false)
    }

    @Test func showsAFilesHistoryAcrossRenamesAndOpensTheFile() async throws {
        let tmp = try await sample()
        let model = HistoryModel(repository: tmp.repository)
        await model.showFileHistory(of: "readme.txt")
        #expect(model.filePath == "readme.txt")
        #expect(model.graph == nil)
        #expect(model.rows.map(\.commit.summary) == ["Edit readme", "Rename notes", "Add notes"])
        #expect(model.rows.map(\.path) == ["readme.txt", "readme.txt", "notes.txt"])
        #expect(model.listDescription == "History of readme.txt · 3 commits")
        #expect(model.selectedFile?.path == "readme.txt")
        guard case .diff(let diff) = model.fileContent else { Issue.record("expected a diff, got \(model.fileContent)"); return }
        #expect(diff.additions == 1)

        // The oldest commit had the file under its old name.
        await model.select(model.rows[2].id)
        #expect(model.selectedFile?.path == "notes.txt")

        await model.clearFileHistory()
        #expect(model.filePath == nil)
        #expect(model.rows.count == 4)
        await model.clearFileHistory()
    }

    @Test func keepsTheOpenFileWhenSteppingThroughCommits() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("one", files: ["a.txt": "1\n", "b.txt": "1\n"])
        try await tmp.commit("two", files: ["a.txt": "2\n", "b.txt": "2\n"])
        try await tmp.commit("three", files: ["a.txt": "3\n"])
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()
        #expect(model.selectedFile == nil, "nothing is opened until a file is picked")
        await model.select(model.neighbour(1))
        #expect(model.selectedCommit?.summary == "two")
        await model.selectFile(model.changedFiles.first { $0.path == "b.txt" })
        await model.select(model.neighbour(1))
        #expect(model.selectedCommit?.summary == "one")
        #expect(model.selectedFile?.path == "b.txt")
        #expect(model.neighbour(1) == nil)
        await model.select(model.neighbour(-2))
        #expect(model.selectedCommit?.summary == "three")
        #expect(model.selectedFile == nil, "three didn't touch b.txt")
    }

    @Test func blamesTheSelectedFileAtTheSelectedCommit() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("first", files: ["f.txt": "a\nb\n"])
        try await tmp.git("commit", "--quiet", "--allow-empty", "-m", "noise")
        try tmp.write("f.txt", "a\nB\n")
        try await tmp.git("commit", "--quiet", "-am", "second", "--author=Bob <bob@example.com>")
        try tmp.write("f.txt", "uncommitted\n")
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()
        await model.selectFile(model.changedFiles.first)
        await model.setFileView(.blame)
        #expect(model.fileView == .blame)
        guard case .blame(let blame) = model.fileContent else { Issue.record("expected blame, got \(model.fileContent)"); return }
        #expect(blame.lines.map(\.text) == ["a", "B"], "blame is of the commit, not the work tree")
        #expect(blame.commit(for: blame.lines[1])?.author.name == "Bob")

        // Jump to the commit that wrote line 1, which isn't the selected one.
        let firstID = blame.lines[0].commitID
        await model.select(firstID)
        #expect(model.selectedCommit?.summary == "first")
        #expect(model.selectedFile?.path == "f.txt")
        guard case .blame(let older) = model.fileContent else { Issue.record("expected blame"); return }
        #expect(older.lines.map(\.text) == ["a", "b"])

        await model.setFileView(.diff)
        guard case .diff = model.fileContent else { Issue.record("expected diff"); return }
    }

    @Test func deletedFilesHaveNoBlameAndBinaryFilesNoDiff() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("add", files: ["gone.txt": "x\n"])
        try tmp.delete("gone.txt")
        try Data([0, 1, 2, 0, 255]).write(to: tmp.url.appendingPathComponent("blob.bin"))
        try await tmp.commit("remove and add binary")
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()
        await model.selectFile(model.changedFiles.first { $0.path == "blob.bin" })
        #expect(model.fileContent == .noPreview("Binary file"))
        await model.selectFile(model.changedFiles.first { $0.path == "gone.txt" })
        await model.setFileView(.blame)
        #expect(model.fileContent == .noPreview("The file was deleted in this commit"))
        await model.selectFile(nil)
        #expect(model.fileContent == .none)
        model.clearSelection()
        #expect(model.selectedCommit == nil)
        #expect(model.changedFiles.isEmpty)
    }

    @Test func emptyRepositoryHasNoHistory() async throws {
        let tmp = try await TemporaryRepository()
        let model = HistoryModel(repository: tmp.repository)
        await model.reload()
        #expect(model.rows.isEmpty)
        #expect(model.selectedCommit == nil)
        #expect(model.graph?.rows.isEmpty == true)
        #expect(model.errorMessage == nil)
        await model.select(nil)
        #expect(model.neighbour(1) == nil)
    }

    @Test func selectingAnUnknownCommitReportsAnError() async throws {
        let tmp = try await sample()
        let model = HistoryModel(repository: tmp.repository)
        await model.select("0123456789012345678901234567890123456789")
        #expect(model.errorMessage != nil)
    }

    @Test func repositoryModelReloadsHistoryOnlyWhenRefsMove() async throws {
        let tmp = try await sample()
        let repo = RepositoryModel(repository: tmp.repository)
        await repo.refresh()
        #expect(repo.history.hasLoaded == false, "history loads lazily")
        await repo.historyAppeared()
        #expect(repo.history.rows.count == 4)
        await repo.historyAppeared()

        try await tmp.commit("From the terminal")
        await repo.refresh()
        #expect(repo.history.rows.first?.commit.summary == "From the terminal")
        #expect(repo.history.selectedCommit?.summary == "Edit readme", "the selection survives a reload")

        await repo.showHistory(of: "src/App.swift")
        #expect(repo.section == .history)
        #expect(repo.history.rows.map(\.commit.summary) == ["Add notes"])
    }
}
