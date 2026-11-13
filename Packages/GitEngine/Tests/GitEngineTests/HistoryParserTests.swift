import Foundation
import Testing
@testable import GitEngine

@Suite("Name-status, file history and blame parsers")
struct HistoryParserTests {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)
    private let c = String(repeating: "c", count: 40)

    private func record(_ id: String, parents: String = "", message: String) -> [String] {
        [id, parents, "Ann", "ann@x", "100", "Ann", "ann@x", "100", "", message + "\n"]
    }

    @Test func parsesNameStatusIncludingRenamesAndCopies() throws {
        let data = Data("M\0edit.txt\0R087\0old name.txt\0new name.txt\0A\0café.txt\0D\0gone\0C100\0src\0copy\0T\0link\0".utf8)
        let changes = try NameStatusParser.parse(data)
        #expect(changes == [
            CommitFileChange(change: .modified, path: "edit.txt"),
            CommitFileChange(change: .renamed(similarity: 87), path: "new name.txt", oldPath: "old name.txt"),
            CommitFileChange(change: .added, path: "café.txt"),
            CommitFileChange(change: .deleted, path: "gone"),
            CommitFileChange(change: .copied(similarity: 100), path: "copy", oldPath: "src"),
            CommitFileChange(change: .typeChanged, path: "link"),
        ])
        #expect(changes[1].pathspec == ["old name.txt", "new name.txt"])
        #expect(changes[0].pathspec == ["edit.txt"])
    }

    @Test func nameStatusRejectsGarbage() throws {
        #expect(throws: GitError.self) { try NameStatusParser.parse(Data("hello\0world\0".utf8)) }
        #expect(throws: GitError.self) { try NameStatusParser.parse(Data("R100\0only-one\0".utf8)) }
        #expect(try NameStatusParser.parse(Data()).isEmpty)
    }

    @Test func parsesFileHistoryWithRenamesAndMerges() throws {
        // Newest first: an edit, a merge (no diff), the rename, then the add under the old name.
        var fields: [String] = []
        fields += record(a, parents: b, message: "edit")
        fields += ["\nM", "new.txt"]
        fields += record(c, parents: "\(b) \(a)", message: "merge")
        fields += record(b, parents: a, message: "rename")
        fields += ["\nR100", "old.txt", "new.txt"]
        fields += record(a, message: "add")
        fields += ["\nA", "old.txt"]
        let data = Data((fields.joined(separator: "\0") + "\0").utf8)

        let entries = try FileHistoryParser.parse(data, path: "new.txt")
        #expect(entries.map(\.commit.summary) == ["edit", "merge", "rename", "add"])
        #expect(entries.map(\.path) == ["new.txt", "new.txt", "new.txt", "old.txt"])
        #expect(entries[1].change == nil)
        #expect(entries[2].change?.oldPath == "old.txt")
        #expect(entries[3].change?.change == .added)
    }

    @Test func fileHistoryRejectsCutShortRecords() {
        let data = Data((record(a, message: "x").prefix(5).joined(separator: "\0") + "\0").utf8)
        #expect(throws: GitError.self) { try FileHistoryParser.parse(data, path: "x") }
    }

    @Test func parsesBlamePorcelain() throws {
        let zero = String(repeating: "0", count: 40)
        let porcelain = """
        \(a) 1 1 2
        author Ann Lee
        author-mail <ann@example.com>
        author-time 1000
        author-tz +0000
        committer Cat
        committer-mail <cat@example.com>
        committer-time 2000
        committer-tz +0100
        summary First commit
        boundary
        filename old.txt
        \tline one
        \(a) 2 2
        \tline\ttwo
        \(b) 5 3 1
        author Bob
        author-mail <bob@example.com>
        author-time 3000
        author-tz +0000
        committer Bob
        committer-mail <bob@example.com>
        committer-time 3000
        committer-tz +0000
        summary Second
        previous \(a) old.txt
        filename new.txt
        \t
        \(zero) 4 4 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 4000
        author-tz +0000
        committer Not Committed Yet
        committer-mail <not.committed.yet>
        committer-time 4000
        committer-tz +0000
        summary Version of new.txt from new.txt
        filename new.txt
        \tdraft
        \(a) 3 5
        \tline three

        """
        let blame = try BlameParser.parse(Data(porcelain.utf8), path: "new.txt")
        #expect(blame.lines.map(\.text) == ["line one", "line\ttwo", "", "draft", "line three"])
        #expect(blame.lines.map(\.lineNumber) == [1, 2, 3, 4, 5])
        #expect(blame.lines[2].originalLineNumber == 5)
        #expect(blame.lines[0].originalPath == "old.txt")
        #expect(blame.lines[2].originalPath == "new.txt")

        let first = try #require(blame.commit(for: blame.lines[0]))
        #expect(first.author == Signature(name: "Ann Lee", email: "ann@example.com", date: Date(timeIntervalSince1970: 1000)))
        #expect(first.committer.name == "Cat")
        #expect(first.committer.date == Date(timeIntervalSince1970: 2000))
        #expect(first.summary == "First commit")
        #expect(first.isBoundary)
        #expect(!first.isUncommitted)
        #expect(blame.commits[b]?.isBoundary == false)
        #expect(blame.commits[zero]?.isUncommitted == true)

        #expect(blame.groups == [
            BlameGroup(commitID: a, range: 0..<2),
            BlameGroup(commitID: b, range: 2..<3),
            BlameGroup(commitID: zero, range: 3..<4),
            BlameGroup(commitID: a, range: 4..<5),
        ])
    }

    @Test func blameKeepsInvalidUTF8LinesReadable() throws {
        var data = Data("\(a) 1 1 1\nauthor A\nsummary s\nfilename f\n\t".utf8)
        data.append(contentsOf: [0x63, 0x61, 0x66, 0xE9]) // "caf" + Latin-1 é
        data.append(contentsOf: Array("\n".utf8))
        let blame = try BlameParser.parse(data, path: "f")
        #expect(blame.lines.count == 1)
        #expect(blame.lines[0].text.hasPrefix("caf"))
    }

    @Test func blameRejectsBadHeaders() throws {
        #expect(throws: GitError.self) { try BlameParser.parse(Data("not a header\n".utf8), path: "f") }
        #expect(throws: GitError.self) { try BlameParser.parse(Data("\tcontent first\n".utf8), path: "f") }
        #expect(try BlameParser.parse(Data(), path: "f").lines.isEmpty)
    }

    @Test func searchArgumentsAreAttachedSoTheyCantBecomeOptions() {
        let query = LogQuery(messagePattern: "--all", authorPattern: "ann", contentPattern: "-p")
        #expect(query.filterArguments == ["--grep=--all", "--author=ann", "-S-p", "--fixed-strings", "--regexp-ignore-case"])
        let regex = LogQuery(messagePattern: "fix.*", fixedStrings: false, ignoreCase: false)
        #expect(regex.filterArguments == ["--grep=fix.*"])
        #expect(LogQuery(contentPattern: "x").filterArguments == ["-Sx"], "case and fixed-string flags only affect --grep and --author")
        #expect(LogQuery(messagePattern: "").filterArguments.isEmpty)
    }

    @Test func pathSearchEscapesGlobCharacters() {
        #expect(LogQuery.pathsContaining("View") == [":(glob,icase)**/*View*", ":(glob,icase)**/*View*/**"])
        #expect(LogQuery.pathsContaining("a*b?[c]").first == #":(glob,icase)**/*a\*b\?\[c\]*"#)
    }
}
