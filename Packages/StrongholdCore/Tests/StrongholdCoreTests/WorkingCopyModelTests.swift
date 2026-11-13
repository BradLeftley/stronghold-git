import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

@MainActor private var keepAlive: [RepositoryModel] = []
@MainActor private var keepAliveRepositories: [TemporaryRepository] = []

@MainActor
@Suite("Working copy model")
struct WorkingCopyModelTests {
    private static let ten = (1...10).map { "line \($0)\n" }.joined()

    /// A repository model over a fixture with `a.txt`, `b.txt` and `c.txt` committed.
    private func setUp(_ configure: (TemporaryRepository) async throws -> Void = { _ in }) async throws
        -> (TemporaryRepository, RepositoryModel, WorkingCopyModel) {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("init", files: ["a.txt": Self.ten, "b.txt": Self.ten, "c.txt": Self.ten])
        try await configure(tmp)
        let model = RepositoryModel(repository: tmp.repository)
        // The working copy only holds its repository model weakly, as the app does; keep it alive here.
        keepAlive.append(model)
        keepAliveRepositories.append(tmp)
        await model.refresh()
        return (tmp, model, model.workingCopy)
    }

    private func unstaged(_ path: String) -> FileSelection { FileSelection(path: path, area: .unstaged) }
    private func staged(_ path: String) -> FileSelection { FileSelection(path: path, area: .staged) }

    // MARK: Selection and diffs

    @Test func firstRefreshSelectsTheFirstChangedFileAndLoadsItsDiff() async throws {
        let (_, _, wc) = try await setUp { try $0.write("b.txt", "changed\n"); try $0.write("a.txt", "changed\n") }
        #expect(wc.selection == [unstaged("a.txt")])
        #expect(wc.currentFile?.path == "a.txt")
        #expect(wc.unstaged.map(\.path) == ["a.txt", "b.txt"])
    }

    @Test func aCleanRepositoryHasNoSelection() async throws {
        let (_, _, wc) = try await setUp()
        #expect(wc.selection.isEmpty)
        #expect(wc.diff == .none)
        #expect(!wc.canCommit)
    }

    @Test func stagedAndUnstagedViewsOfOneFileShowDifferentDiffs() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "staged\n" + Self.ten) }
        try await tmp.git("add", "a.txt")
        try tmp.write("a.txt", "staged\n" + Self.ten + "unstaged\n")
        await wc.reloadStatusForTest()
        await wc.select([staged("a.txt")])
        #expect(wc.currentFile?.additions == 1 && wc.currentFile?.hunks[0].lines.contains { $0.text == "staged" } == true)
        await wc.select([unstaged("a.txt")])
        #expect(wc.currentFile?.hunks[0].lines.contains { $0.text == "unstaged" } == true)
    }

    @Test func untrackedBinaryAndConflictedFilesHaveSensiblePreviews() async throws {
        let (tmp, _, wc) = try await setUp {
            try $0.write("new.txt", "hello\n")
            try $0.write("blob.bin", "a\u{0}b\u{0}\n")
            try $0.write("empty.txt", "")
        }
        await wc.select([unstaged("new.txt")])
        #expect(wc.currentFile?.change == .added && wc.currentFile?.additions == 1)
        await wc.select([unstaged("blob.bin")])
        #expect(wc.diff == .noPreview("Binary file"))
        await wc.select([unstaged("empty.txt")])
        #expect(wc.diff == .noPreview("Empty file"))
        _ = tmp
    }

    @Test func multipleSelectionShowsNoSingleDiff() async throws {
        let (_, _, wc) = try await setUp { try $0.write("a.txt", "1\n"); try $0.write("b.txt", "2\n") }
        await wc.select([unstaged("a.txt"), unstaged("b.txt")])
        #expect(wc.diff == .multiple(count: 2))
        #expect(wc.focusedSelection == nil)
        await wc.select([])
        #expect(wc.diff == .none)
    }

    @Test func conflictedFilesAreMarkedForTheMergeEditor() async throws {
        let (tmp, model, wc) = try await setUp()
        try await tmp.git("checkout", "--quiet", "-b", "other")
        try await tmp.commit("other", files: ["a.txt": "other\n"])
        try await tmp.git("checkout", "--quiet", "main")
        try await tmp.commit("main", files: ["a.txt": "main\n"])
        _ = try? await tmp.repository.git.run(["merge", "other"], in: tmp.url)
        await model.refresh()
        #expect(wc.conflicted.map(\.path) == ["a.txt"])
        await wc.select([FileSelection(path: "a.txt", area: .conflicted)])
        #expect(wc.diff == .conflict)
        #expect(!wc.supportsLineSelection)
    }

    // MARK: Whole files

    @Test func stagingAFileMovesItAndSelectsItsNeighbour() async throws {
        let (_, _, wc) = try await setUp {
            for name in ["a", "b", "c"] { try $0.write("\(name).txt", "changed \(name)\n") }
        }
        await wc.select([unstaged("b.txt")])
        await wc.stage([unstaged("b.txt")])
        #expect(wc.staged.map(\.path) == ["b.txt"])
        #expect(wc.unstaged.map(\.path) == ["a.txt", "c.txt"])
        #expect(wc.selection == [unstaged("c.txt")], "the file now at the same position")
        #expect(wc.currentFile?.path == "c.txt")
    }

    @Test func stagingTheLastFileSelectsThePreviousOne() async throws {
        let (_, _, wc) = try await setUp { for n in ["a", "b"] { try $0.write("\(n).txt", "changed\n") } }
        await wc.select([unstaged("b.txt")])
        await wc.stage([unstaged("b.txt")])
        #expect(wc.selection == [unstaged("a.txt")])
    }

    @Test func stagingEverythingFallsBackToTheStagedList() async throws {
        let (_, _, wc) = try await setUp { try $0.write("a.txt", "changed\n") }
        await wc.stageAll()
        #expect(wc.unstaged.isEmpty)
        #expect(wc.selection == [staged("a.txt")])
        #expect(wc.currentFile?.path == "a.txt")
    }

    @Test func unstagingAStagedRenameRestoresBothPaths() async throws {
        let (tmp, _, wc) = try await setUp()
        try await tmp.git("mv", "a.txt", "renamed.txt")
        await wc.reloadStatusForTest()
        #expect(wc.staged.map(\.path) == ["renamed.txt"])
        await wc.unstage([staged("renamed.txt")])
        #expect(wc.staged.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("renamed.txt").path))
        let entries = Set(wc.unstaged.map(\.path))
        #expect(entries == ["a.txt", "renamed.txt"], "a deletion and an untracked file, nothing left in the index")
    }

    @Test func unstageAllClearsTheIndex() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "1\n"); try $0.write("new.txt", "n\n") }
        try await tmp.git("add", "-A")
        await wc.reloadStatusForTest()
        #expect(wc.staged.count == 2)
        await wc.unstageAll()
        #expect(wc.staged.isEmpty)
        #expect(Set(wc.unstaged.map(\.path)) == ["a.txt", "new.txt"])
    }

    @Test func discardingRestoresTrackedFilesAndDeletesUntrackedOnes() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "changed\n"); try $0.write("new.txt", "n\n") }
        await wc.discard(paths: ["a.txt", "new.txt"])
        #expect(try tmp.read("a.txt") == Self.ten)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("new.txt").path))
        #expect(wc.status.isClean)
        #expect(wc.errorMessage == nil)
    }

    @Test func discardAllLeavesStagedWorkAlone() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "staged\n"); try $0.write("b.txt", "unstaged\n") }
        try await tmp.git("add", "a.txt")
        await wc.reloadStatusForTest()
        await wc.discardAll()
        #expect(try tmp.read("b.txt") == Self.ten)
        #expect(try tmp.read("a.txt") == "staged\n")
        #expect(wc.staged.map(\.path) == ["a.txt"])
    }

    // MARK: Hunks and lines

    @Test func stagingPickedLinesLeavesTheRestUnstaged() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "one\ntwo\n" + Self.ten) }
        let file = try #require(wc.currentFile)
        #expect(wc.supportsLineSelection)
        let two = try #require(file.hunks[0].lines.firstIndex { $0.text == "two" })
        wc.toggleLine(LineSelection(hunk: 0, line: two))
        #expect(wc.lineSelection.count == 1)
        await wc.applySelectedLines()
        #expect(try await tmp.git("show", ":a.txt") == "two\n" + Self.ten)
        #expect(wc.lineSelection.isEmpty, "picks are cleared once the diff changes")
        #expect(wc.currentFile?.additions == 1)
    }

    @Test func togglingALineTwiceUnpicksIt() async throws {
        let (_, _, wc) = try await setUp { try $0.write("a.txt", "x\n" + Self.ten) }
        let line = LineSelection(hunk: 0, line: 0)
        wc.toggleLine(line); wc.toggleLine(line)
        #expect(wc.lineSelection.isEmpty)
    }

    @Test func hunkToggleSelectsAndClearsEveryChangedLine() async throws {
        let (_, _, wc) = try await setUp { try $0.write("a.txt", "x\ny\n" + Self.ten.replacingOccurrences(of: "line 5\n", with: "")) }
        wc.toggleHunk(0)
        let file = try #require(wc.currentFile)
        #expect(wc.lineSelection == PatchBuilder.hunkSelection(of: file, hunk: 0))
        wc.toggleHunk(0)
        #expect(wc.lineSelection.isEmpty)
    }

    @Test func stagingAHunkAndUnstagingItAgain() async throws {
        let (tmp, _, wc) = try await setUp {
            var rows = (1...40).map { "row \($0)\n" }
            try $0.write("a.txt", rows.joined())
            try await $0.git("add", "a.txt"); try await $0.git("commit", "--quiet", "-m", "rows")
            rows[1] = "TOP\n"; rows[37] = "BOTTOM\n"
            try $0.write("a.txt", rows.joined())
        }
        #expect(wc.currentFile?.hunks.count == 2)
        await wc.applyHunk(1)
        #expect(try await tmp.git("show", ":a.txt").contains("BOTTOM"))
        #expect(wc.currentFile?.hunks.count == 1)
        await wc.select([staged("a.txt")])
        #expect(wc.currentFile?.hunks.count == 1)
        await wc.applyHunk(0)
        #expect(try await tmp.git("show", ":a.txt").contains("BOTTOM") == false)
    }

    @Test func discardingAHunkRevertsOnlyThatHunk() async throws {
        let (tmp, _, wc) = try await setUp {
            let rows = (1...40).map { "row \($0)\n" }
            try $0.write("a.txt", rows.joined())
            try await $0.git("add", "a.txt"); try await $0.git("commit", "--quiet", "-m", "rows")
            var edited = rows
            edited[1] = "TOP\n"; edited[37] = "BOTTOM\n"
            try $0.write("a.txt", edited.joined())
        }
        await wc.discardHunk(0)
        let text = try tmp.read("a.txt")
        #expect(text.contains("row 2\n") && text.contains("BOTTOM") && !text.contains("TOP"))
    }

    @Test func discardingPickedLinesNeedsAnUnstagedSelection() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "x\n" + Self.ten) }
        try await tmp.git("add", "a.txt")
        await wc.reloadStatusForTest()
        await wc.select([staged("a.txt")])
        wc.toggleHunk(0)
        await wc.discardSelectedLines()
        #expect(try tmp.read("a.txt") == "x\n" + Self.ten, "the staged side is never discarded")
    }

    @Test func aFileThatCannotBePatchedHasNoLineSelection() async throws {
        let (tmp, _, wc) = try await setUp()
        try await tmp.git("mv", "a.txt", "moved.txt")
        await wc.reloadStatusForTest()
        await wc.select([staged("moved.txt")])
        #expect(!wc.supportsLineSelection)
    }

    @Test func aFailedActionIsReportedAndRecovers() async throws {
        let (tmp, _, wc) = try await setUp { try $0.write("a.txt", "x\n" + Self.ten) }
        // Make the patch stale: the file's staged content no longer matches the diff the model holds.
        try await tmp.git("add", "a.txt")
        try await tmp.git("commit", "--quiet", "-m", "meanwhile")
        wc.toggleHunk(0)
        await wc.applySelectedLines()
        #expect(wc.errorMessage != nil)
        wc.dismissError()
        #expect(wc.errorMessage == nil)
        #expect(!wc.isBusy)
        #expect(wc.status.isClean, "the list refreshed to what is really on disk")
    }

    // MARK: Committing

    @Test func commitNeedsStagedFilesAndAMessage() async throws {
        let (_, _, wc) = try await setUp { try $0.write("a.txt", "x\n") }
        wc.commitMessage = "Message"
        #expect(!wc.canCommit, "nothing staged")
        await wc.stageAll()
        #expect(wc.canCommit)
        wc.commitMessage = " \n "
        #expect(!wc.canCommit, "blank message")
        #expect(await wc.commit() == false)
    }

    @Test func committingMakesTheCommitAndResetsTheForm() async throws {
        let (tmp, model, wc) = try await setUp { try $0.write("a.txt", "x\n"); try $0.write("b.txt", "y\n") }
        await wc.stage([unstaged("a.txt")])
        wc.commitMessage = "Change a\n\nWith a body."
        #expect(await wc.commit())
        #expect(wc.commitMessage.isEmpty && !wc.amend)
        #expect(wc.lastCommit?.summary == "Change a")
        #expect(model.commits.first?.summary == "Change a")
        #expect(model.commits.first?.message.contains("With a body.") == true)
        #expect(wc.staged.isEmpty)
        #expect(wc.unstaged.map(\.path) == ["b.txt"], "other changes stay")
        #expect(try await tmp.git("show", "--format=", "--name-only", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "a.txt")
    }

    @Test func amendPrefillsTheLastMessageAndRestoresTheDraft() async throws {
        let (_, model, wc) = try await setUp { try $0.write("a.txt", "x\n") }
        wc.commitMessage = "half-written draft"
        await wc.setAmend(true)
        #expect(wc.commitMessage == "half-written draft", "an existing draft is not overwritten")
        await wc.setAmend(false)
        wc.commitMessage = ""
        await wc.setAmend(true)
        #expect(wc.commitMessage == "init")
        #expect(wc.canCommit, "an amend can reword with nothing staged")
        await wc.setAmend(false)
        #expect(wc.commitMessage.isEmpty)
        _ = model
    }

    @Test func amendingRewritesTheLastCommit() async throws {
        let (tmp, model, wc) = try await setUp { try $0.write("a.txt", "x\n") }
        await wc.stageAll()
        await wc.setAmend(true)
        wc.commitMessage = "init, reworded"
        #expect(await wc.commit())
        #expect(model.commits.map(\.summary) == ["init, reworded"])
        #expect(try await tmp.git("show", "HEAD:a.txt") == "x\n")
        #expect(!wc.amend)
        #expect(wc.commitMessage.isEmpty)
    }

    @Test func aRejectingHookSurfacesItsMessage() async throws {
        let (tmp, model, wc) = try await setUp { try $0.write("a.txt", "x\n") }
        let hook = tmp.url.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho 'lint failed: no tabs please' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        await wc.stageAll()
        wc.commitMessage = "Will fail"
        #expect(await wc.commit() == false)
        #expect(wc.errorMessage?.contains("lint failed: no tabs please") == true)
        #expect(wc.commitMessage == "Will fail", "the message is kept so nothing is retyped")
        #expect(wc.staged.map(\.path) == ["a.txt"])
        #expect(model.commits.map(\.summary) == ["init"])
    }

    @Test func theFirstCommitInAnEmptyRepositoryWorks() async throws {
        let tmp = try await TemporaryRepository()
        try tmp.write("first.txt", "hi\n")
        let model = RepositoryModel(repository: tmp.repository)
        keepAlive.append(model)
        keepAliveRepositories.append(tmp)
        await model.refresh()
        let wc = model.workingCopy
        #expect(wc.selection == [unstaged("first.txt")])
        await wc.stageAll()
        wc.commitMessage = "First"
        #expect(await wc.commit())
        #expect(model.commits.map(\.summary) == ["First"])
        await wc.setAmend(true)
        #expect(wc.commitMessage == "First")
    }

    // MARK: Refreshing

    @Test func statusRefreshKeepsAnUnchangedSelectionAndPicks() async throws {
        let (_, model, wc) = try await setUp { try $0.write("a.txt", "x\n" + Self.ten) }
        wc.toggleLine(LineSelection(hunk: 0, line: 0))
        await model.refreshStatus()
        #expect(wc.lineSelection.count == 1, "nothing changed, so the picks stay")
        #expect(wc.selection == [unstaged("a.txt")])
    }

    @Test func externalChangesAppearOnRefresh() async throws {
        let (tmp, model, wc) = try await setUp()
        #expect(wc.status.isClean)
        try tmp.write("c.txt", "outside edit\n")
        await model.refreshStatus()
        #expect(wc.unstaged.map(\.path) == ["c.txt"])
        #expect(wc.selection.isEmpty, "a new change doesn't steal focus from an empty selection")
    }

    @Test func refreshAfterFileChangeCatchesCommitsMadeOutsideTheApp() async throws {
        let (tmp, model, _) = try await setUp()
        try await tmp.commit("from the terminal", files: ["d.txt": "d\n"])
        await model.refreshAfterFileChange()
        #expect(model.commits.first?.summary == "from the terminal")
    }
}

extension WorkingCopyModel {
    /// Reloads status the way the repository model does, for tests that change the repo directly.
    func reloadStatusForTest() async {
        if let status = try? await repository.status() { await statusDidChange(status) }
    }
}
