import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

@Suite("Partial staging, discarding and cloning against real repos")
struct WorkingCopyTests {
    private static let ten = (1...10).map { "line \($0)\n" }.joined()

    /// A repository with `file.txt` committed as ten lines.
    private func fixture(_ contents: String = ten, path: String = "file.txt") async throws -> TemporaryRepository {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("init", files: [path: contents])
        return tmp
    }

    private func diff(_ tmp: TemporaryRepository, _ target: DiffTarget, _ path: String = "file.txt") async throws -> FileDiff {
        let files = try await tmp.repository.diff(target, paths: [path])
        return try #require(files.first)
    }

    private func staged(_ tmp: TemporaryRepository, _ path: String = "file.txt") async throws -> String {
        try await tmp.git("show", ":\(path)")
    }

    /// The selection of the lines whose text is in `texts`.
    private func lines(_ file: FileDiff, _ texts: Set<String>) -> Set<LineSelection> {
        var result = Set<LineSelection>()
        for (h, hunk) in file.hunks.enumerated() {
            for (l, line) in hunk.lines.enumerated() where line.isChange && texts.contains(line.text) {
                result.insert(LineSelection(hunk: h, line: l))
            }
        }
        return result
    }

    // MARK: Staging

    @Test func stagesOneAddedLineOfSeveral() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", "line 1\nnew A\nnew B\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["new B"]))

        #expect(try await staged(tmp) == "line 1\nnew B\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n")
        // The work tree still has both lines; the other one is still unstaged.
        let remaining = try await diff(tmp, .workTree)
        #expect(remaining.additions == 1)
        #expect(remaining.hunks[0].lines.first(where: { $0.kind == .addition })?.text == "new A")
    }

    @Test func stagesOneDeletionAndKeepsTheOther() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 9\nline 10\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["line 8"]))
        #expect(try await staged(tmp) == "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 9\nline 10\n")
        #expect(try await tmp.repository.diff(.workTree).isEmpty)
    }

    @Test func stagesAReplacementHalfAtATime() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", Self.ten.replacingOccurrences(of: "line 5\n", with: "five\n"))
        var file = try await diff(tmp, .workTree)
        // Stage only the addition: the old line stays in the index next to the new one.
        try await tmp.repository.stageLines(of: file, lines(file, ["five"]))
        #expect(try await staged(tmp) == Self.ten.replacingOccurrences(of: "line 5\n", with: "line 5\nfive\n"))
        // Now the deletion.
        file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, PatchBuilder.fullSelection(of: file))
        #expect(try await staged(tmp) == Self.ten.replacingOccurrences(of: "line 5\n", with: "five\n"))
        #expect(try await tmp.repository.diff(.workTree).isEmpty)
    }

    @Test func stagesOnlyTheChosenHunkOfSeveral() async throws {
        let tmp = try await fixture((1...40).map { "row \($0)\n" }.joined())
        var edited = (1...40).map { "row \($0)\n" }
        edited[1] = "TOP\n"
        edited[37] = "BOTTOM\n"
        try tmp.write("file.txt", edited.joined())
        let file = try await diff(tmp, .workTree)
        #expect(file.hunks.count == 2)
        try await tmp.repository.stageLines(of: file, PatchBuilder.hunkSelection(of: file, hunk: 1))

        let indexed = try await staged(tmp)
        #expect(indexed.contains("BOTTOM") && !indexed.contains("TOP"))
        let rest = try await diff(tmp, .workTree)
        #expect(rest.hunks.count == 1 && rest.hunks[0].lines.contains { $0.text == "TOP" })
    }

    @Test func stagingTheSecondHunkAfterTheFirstWasStagedStillApplies() async throws {
        let tmp = try await fixture((1...40).map { "row \($0)\n" }.joined())
        var edited = (1...40).map { "row \($0)\n" }
        edited.insert("inserted\n", at: 2)
        edited[38] = "BOTTOM\n"
        try tmp.write("file.txt", edited.joined())
        var file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, PatchBuilder.hunkSelection(of: file, hunk: 0))
        file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, PatchBuilder.hunkSelection(of: file, hunk: 0))
        #expect(try await tmp.repository.diff(.workTree).isEmpty)
        #expect(try await staged(tmp) == edited.joined())
    }

    @Test func stagesLinesAtTheStartAndEndOfAFile() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", "first\nsecond\n" + Self.ten + "last\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["second", "last"]))
        #expect(try await staged(tmp) == "second\n" + Self.ten + "last\n")
    }

    @Test func stagesIntoAnEmptyFile() async throws {
        let tmp = try await fixture("")
        try tmp.write("file.txt", "a\nb\nc\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["b"]))
        #expect(try await staged(tmp) == "b\n")
    }

    @Test func stagesPartOfAnUntrackedFile() async throws {
        let tmp = try await fixture()
        try tmp.write("new.txt", "one\ntwo\nthree\n")
        let files = try await tmp.repository.untrackedDiff(for: "new.txt")
        let file = try #require(files.first)
        #expect(file.change == .added)
        try await tmp.repository.stageLines(of: file, lines(file, ["one", "three"]))
        #expect(try await staged(tmp, "new.txt") == "one\nthree\n")
        // The rest shows up as an unstaged addition of "two".
        let rest = try await diff(tmp, .workTree, "new.txt")
        #expect(rest.additions == 1 && rest.deletions == 0)
    }

    @Test func stagesAWholeUntrackedFileThroughPatches() async throws {
        let tmp = try await fixture()
        try tmp.write("new.txt", "one\ntwo\n")
        let file = try #require(try await tmp.repository.untrackedDiff(for: "new.txt").first)
        try await tmp.repository.stageLines(of: file, PatchBuilder.fullSelection(of: file))
        #expect(try await staged(tmp, "new.txt") == "one\ntwo\n")
        #expect(try await tmp.repository.status().entries.first { $0.path == "new.txt" }?.index == .added)
    }

    @Test func stagesLinesOfAFileWithSpacesAndUnicodeInItsName() async throws {
        let path = "my docs/café notes.txt"
        let tmp = try await fixture("a\nb\nc\n", path: path)
        try tmp.write(path, "a\nB\nb\nc\nd\n")
        let file = try await diff(tmp, .workTree, path)
        try await tmp.repository.stageLines(of: file, lines(file, ["d"]))
        #expect(try await staged(tmp, path) == "a\nb\nc\nd\n")
    }

    @Test func stagesLinesOfAFileWithWindowsLineEndings() async throws {
        let tmp = try await fixture("a\r\nb\r\nc\r\n")
        try await tmp.git("config", "core.autocrlf", "false")
        try tmp.write("file.txt", "a\r\nx\r\nb\r\nc\r\ny\r\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["y\r"]))
        #expect(try await staged(tmp) == "a\r\nb\r\nc\r\ny\r\n")
    }

    @Test func stagesAFileWithoutATrailingNewlineWhenEverythingIsSelected() async throws {
        let tmp = try await fixture("a\nb")
        try tmp.write("file.txt", "a\nb\nc")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, PatchBuilder.fullSelection(of: file))
        #expect(try await staged(tmp) == "a\nb\nc")
    }

    @Test func stagesAWholeDeletedFileThroughPatches() async throws {
        let tmp = try await fixture()
        try tmp.delete("file.txt")
        let file = try await diff(tmp, .workTree)
        #expect(file.change == .deleted)
        try await tmp.repository.stageLines(of: file, PatchBuilder.fullSelection(of: file))
        let entry = try #require(try await tmp.repository.status().entries.first)
        #expect(entry.index == .deleted)
    }

    @Test func stagesSomeLinesOfADeletedFile() async throws {
        let tmp = try await fixture("a\nb\nc\n")
        try tmp.delete("file.txt")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.stageLines(of: file, lines(file, ["a"]))
        #expect(try await staged(tmp) == "b\nc\n")
    }

    // MARK: Unstaging

    @Test func unstagesOneLineOfSeveralStagedLines() async throws {
        let tmp = try await fixture()
        let edited = "line 1\nnew A\nnew B\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n"
        try tmp.write("file.txt", edited)
        try await tmp.git("add", "file.txt")
        let file = try await diff(tmp, .staged)
        try await tmp.repository.unstageLines(of: file, lines(file, ["new A"]))

        #expect(try await staged(tmp) == edited.replacingOccurrences(of: "new A\n", with: ""))
        #expect(try tmp.read("file.txt") == edited)
        let rest = try await diff(tmp, .workTree)
        #expect(rest.hunks[0].lines.first(where: { $0.kind == .addition })?.text == "new A")
    }

    @Test func unstagesAWholeHunkOfSeveral() async throws {
        let tmp = try await fixture((1...40).map { "row \($0)\n" }.joined())
        var edited = (1...40).map { "row \($0)\n" }
        edited[1] = "TOP\n"
        edited[37] = "BOTTOM\n"
        try tmp.write("file.txt", edited.joined())
        try await tmp.git("add", "file.txt")
        let file = try await diff(tmp, .staged)
        try await tmp.repository.unstageLines(of: file, PatchBuilder.hunkSelection(of: file, hunk: 0))
        let indexed = try await staged(tmp)
        #expect(indexed.contains("BOTTOM") && !indexed.contains("TOP") && indexed.contains("row 2"))
    }

    @Test func unstagesAWholeNewFileLineByLine() async throws {
        let tmp = try await fixture()
        try tmp.write("new.txt", "one\ntwo\nthree\n")
        try await tmp.git("add", "new.txt")
        var file = try await diff(tmp, .staged, "new.txt")
        try await tmp.repository.unstageLines(of: file, lines(file, ["two"]))
        #expect(try await staged(tmp, "new.txt") == "one\nthree\n")
        file = try await diff(tmp, .staged, "new.txt")
        try await tmp.repository.unstageLines(of: file, PatchBuilder.fullSelection(of: file))
        #expect(try await tmp.repository.status().entries.first { $0.path == "new.txt" }?.kind == .untracked)
    }

    // MARK: Discarding

    @Test func discardsOneLineAndKeepsTheOtherChanges() async throws {
        let tmp = try await fixture()
        let edited = "line 1\nnew A\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nnew B\n"
        try tmp.write("file.txt", edited)
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.discardLines(of: file, lines(file, ["new A"]))
        #expect(try tmp.read("file.txt") == edited.replacingOccurrences(of: "new A\n", with: ""))
    }

    @Test func discardingADeletedLineBringsItBack() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", Self.ten.replacingOccurrences(of: "line 3\nline 4\n", with: ""))
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.discardLines(of: file, lines(file, ["line 4"]))
        #expect(try tmp.read("file.txt") == Self.ten.replacingOccurrences(of: "line 3\n", with: ""))
    }

    @Test func discardLeavesTheIndexAlone() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", Self.ten + "added\n")
        try await tmp.git("add", "file.txt")
        try tmp.write("file.txt", Self.ten + "added\nmore\n")
        let file = try await diff(tmp, .workTree)
        try await tmp.repository.discardLines(of: file, PatchBuilder.fullSelection(of: file))
        #expect(try tmp.read("file.txt") == Self.ten + "added\n")
        #expect(try await staged(tmp) == Self.ten + "added\n")
    }

    @Test func discardChangesRestoresTrackedAndDeletesUntracked() async throws {
        let tmp = try await fixture()
        try await tmp.commit("second", files: ["other.txt": "keep\n"])
        try tmp.write("file.txt", "changed\n")
        try tmp.delete("other.txt")
        try tmp.write("junk/new.txt", "x\n")
        try tmp.write("staged.txt", "s\n")
        try await tmp.git("add", "staged.txt")

        try await tmp.repository.discardChanges(tracked: ["file.txt", "other.txt"], untracked: ["junk/new.txt"])
        #expect(try tmp.read("file.txt") == Self.ten)
        #expect(try tmp.read("other.txt") == "keep\n")
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("junk/new.txt").path))
        // Staged work is not touched.
        #expect(try tmp.read("staged.txt") == "s\n")
    }

    // MARK: Patches

    @Test func buildingAPatchWithNothingSelectedGivesNil() async throws {
        let tmp = try await fixture()
        try tmp.write("file.txt", Self.ten + "x\n")
        let file = try await diff(tmp, .workTree)
        #expect(PatchBuilder.patch(for: file, selecting: [], intent: .stage) == nil)
        // A selection of a context line is not a change either.
        #expect(PatchBuilder.patch(for: file, selecting: [LineSelection(hunk: 0, line: 0)], intent: .stage) == nil)
    }

    @Test func binaryFilesRenamesAndModeChangesAreWholeFileOnly() async throws {
        let tmp = try await fixture()
        try tmp.write("bin.dat", "a\u{0}b\u{0}\n")
        let binary = try #require(try await tmp.repository.untrackedDiff(for: "bin.dat").first)
        #expect(binary.isBinary && !PatchBuilder.supportsPartialChanges(binary))

        try await tmp.git("mv", "file.txt", "renamed.txt")
        let renamed = try #require(try await tmp.repository.diff(.staged).first { $0.path == "renamed.txt" })
        #expect(!PatchBuilder.supportsPartialChanges(renamed))
        #expect(PatchBuilder.patch(for: renamed, selecting: PatchBuilder.fullSelection(of: renamed), intent: .unstage) == nil)
    }

    @Test func quotesPathsThatNeedIt() {
        #expect(PatchBuilder.quoted("plain/path.txt") == "plain/path.txt")
        #expect(PatchBuilder.quoted("my docs/café.txt") == "my docs/café.txt")
        #expect(PatchBuilder.quoted("we\"ird\\name") == "\"we\\\"ird\\\\name\"")
        #expect(PatchBuilder.quoted("tab\there") == "\"tab\\there\"")
    }

    // MARK: Untracked previews

    @Test func untrackedDiffShowsTheWholeFileAsAdded() async throws {
        let tmp = try await fixture()
        try tmp.write("sub dir/new file.txt", "x\ny\n")
        let file = try #require(try await tmp.repository.untrackedDiff(for: "sub dir/new file.txt").first)
        #expect(file.change == .added)
        #expect(file.path == "sub dir/new file.txt")
        #expect(file.additions == 2)
    }

    @Test func untrackedDiffOfAnEmptyFileHasNoHunks() async throws {
        let tmp = try await fixture()
        try tmp.write("empty.txt", "")
        let file = try #require(try await tmp.repository.untrackedDiff(for: "empty.txt").first)
        #expect(file.hunks.isEmpty)
    }

    @Test func untrackedDiffOfADirectoryIsEmpty() async throws {
        let tmp = try await fixture()
        try tmp.write("folder/a.txt", "a\n")
        #expect(try await tmp.repository.untrackedDiff(for: "folder").isEmpty)
        #expect(try await tmp.repository.untrackedDiff(for: "missing.txt").isEmpty)
    }

    // MARK: Commit helpers

    @Test func headMessageReturnsTheFullMessageOrNil() async throws {
        let tmp = try await TemporaryRepository()
        #expect(try await tmp.repository.headMessage() == nil)
        try await tmp.commit("Subject line\n\nBody paragraph.", files: ["a.txt": "a"])
        #expect(try await tmp.repository.headMessage() == "Subject line\n\nBody paragraph.")
    }

    // MARK: Cloning

    @Test func clonesALocalRepository() async throws {
        let source = try await fixture()
        let destination = source.baseURL.appendingPathComponent("clones/copy")
        let clone = try await Repository.clone(from: source.url.path, to: destination, git: source.git)
        #expect(clone.rootURL.lastPathComponent == "copy")
        #expect(try await clone.log().map(\.summary) == ["init"])
        #expect(try await clone.remotes().first?.name == "origin")
    }

    @Test func aFailedCloneLeavesNothingBehind() async throws {
        let source = try await fixture()
        let destination = source.baseURL.appendingPathComponent("clones/nothing")
        await #expect(throws: GitError.self) {
            _ = try await Repository.clone(from: source.baseURL.appendingPathComponent("does-not-exist").path,
                                           to: destination, git: source.git)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cloneRefusesTransportsThatRunCommands() async throws {
        let source = try await fixture()
        let destination = source.baseURL.appendingPathComponent("clones/pwned")
        let marker = source.baseURL.appendingPathComponent("marker")
        await #expect(throws: GitError.self) {
            _ = try await Repository.clone(from: "ext::sh -c 'touch \(marker.path)'", to: destination, git: source.git)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cloneRejectsAnEmptyAddress() async throws {
        let source = try await fixture()
        await #expect(throws: GitError.self) {
            _ = try await Repository.clone(from: "  ", to: source.baseURL.appendingPathComponent("x"), git: source.git)
        }
    }

    @Test func cloneIntoAnExistingFolderKeepsTheFolderOnFailure() async throws {
        let source = try await fixture()
        let destination = source.baseURL.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: destination.appendingPathComponent("keep.txt"))
        await #expect(throws: GitError.self) {
            _ = try await Repository.clone(from: source.url.path, to: destination, git: source.git)
        }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("keep.txt").path))
    }

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "repo"),
        ("https://github.com/owner/repo", "repo"),
        ("https://github.com/owner/repo/", "repo"),
        ("git@github.com:owner/my-project.git", "my-project"),
        ("ssh://git@host:2222/team/thing.git", "thing"),
        ("/Users/me/code/local", "local"),
        ("", ""),
    ])
    func derivesAFolderNameFromTheAddress(remote: String, name: String) {
        #expect(Repository.defaultFolderName(forRemote: remote) == name)
    }
}
