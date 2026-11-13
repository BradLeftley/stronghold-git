import Foundation
import Testing
@testable import GitEngine

@Suite("Status parser")
struct StatusParserTests {
    private func data(_ records: [String]) -> Data { Data(records.joined(separator: "\0").utf8 + [0]) }

    @Test func parsesBranchHeaders() throws {
        let status = try StatusParser.parse(data([
            "# branch.oid 1111111111111111111111111111111111111111",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +3 -2",
            "# stash 4",
            "# some.future.header value",
        ]))
        #expect(status.branch == BranchStatus(headOID: String(repeating: "1", count: 40), branch: "feature/x",
                                              upstream: "origin/feature/x", ahead: 3, behind: 2))
        #expect(status.stashCount == 4)
        #expect(status.isClean)
    }

    @Test func parsesInitialAndDetached() throws {
        let status = try StatusParser.parse(data(["# branch.oid (initial)", "# branch.head (detached)"]))
        #expect(status.branch.isUnborn)
        #expect(status.branch.isDetached)
    }

    @Test func parsesOrdinaryEntriesWithSpacesInPaths() throws {
        let h = String(repeating: "a", count: 40)
        let status = try StatusParser.parse(data([
            "1 M. N... 100644 100644 100644 \(h) \(h) dir/file with spaces.txt",
            "1 .D N... 100644 100644 000000 \(h) \(h) gone.txt",
            "1 AM N... 000000 100644 100644 \(h) \(h) new.txt",
        ]))
        #expect(status.entries.count == 3)
        #expect(status.entries[0].path == "dir/file with spaces.txt")
        #expect(status.entries[0].index == .modified)
        #expect(status.entries[0].workTree == .unmodified)
        #expect(status.entries[0].hasStagedChanges && !status.entries[0].hasUnstagedChanges)
        #expect(status.entries[1].workTree == .deleted)
        #expect(status.entries[2].hasStagedChanges && status.entries[2].hasUnstagedChanges)
        #expect(status.staged.map(\.path) == ["dir/file with spaces.txt", "new.txt"])
        #expect(status.unstaged.map(\.path) == ["gone.txt", "new.txt"])
        #expect(!status.isClean)
    }

    @Test func parsesRenamesAndCopiesWithOriginalPath() throws {
        let h = String(repeating: "b", count: 40)
        let status = try StatusParser.parse(data([
            "2 R. N... 100644 100644 100644 \(h) \(h) R87 new name.txt", "old name.txt",
            "2 C. N... 100644 100644 100644 \(h) \(h) C100 copy.txt", "source.txt",
            "? untracked.txt",
        ]))
        #expect(status.entries.count == 3)
        #expect(status.entries[0].kind == .renamed(similarity: 87))
        #expect(status.entries[0].path == "new name.txt")
        #expect(status.entries[0].originalPath == "old name.txt")
        #expect(status.entries[1].kind == .copied(similarity: 100))
        #expect(status.entries[2].kind == .untracked)
    }

    @Test func parsesUnmergedUntrackedIgnoredAndSubmodules() throws {
        let h = String(repeating: "c", count: 40)
        let status = try StatusParser.parse(data([
            "u UU N... 100644 100644 100644 100644 \(h) \(h) \(h) conflict.txt",
            "u DU N... 100644 000000 100644 100644 \(h) \(h) \(h) deleted-by-us.txt",
            "1 .M SCMU 160000 160000 160000 \(h) \(h) vendor/lib",
            "? new dir/a.txt",
            "! build/out.o",
        ]))
        #expect(status.entries[0].kind == .unmerged(.bothModified))
        #expect(status.entries[0].isConflicted)
        #expect(!status.entries[0].hasStagedChanges && !status.entries[0].hasUnstagedChanges)
        #expect(status.entries[1].kind == .unmerged(.deletedByUs))
        #expect(status.entries[2].submodule == SubmoduleState(commitChanged: true, hasTrackedChanges: true,
                                                              hasUntrackedChanges: true))
        #expect(status.entries[3].path == "new dir/a.txt")
        #expect(status.entries[4].kind == .ignored)
        #expect(status.conflicted.count == 2)
    }

    @Test func emptyOutputIsClean() throws {
        let status = try StatusParser.parse(Data())
        #expect(status == RepositoryStatus())
    }

    @Test(arguments: [
        "1 M. N... too few fields",
        "2 R. N... 100644 100644 100644 a b R100 path-without-original",
        "u ZZ N... 1 2 3 4 a b c path",
        "1 Q. N... 100644 100644 100644 a b path",
        "X unknown",
        "? ",
    ])
    func rejectsMalformedLines(_ line: String) {
        #expect(throws: GitError.self) { try StatusParser.parse(data([line])) }
    }
}
