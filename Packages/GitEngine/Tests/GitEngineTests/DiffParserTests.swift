import Foundation
import Testing
@testable import GitEngine

@Suite("Diff parser")
struct DiffParserTests {
    @Test func parsesModifiedFileWithLineNumbers() throws {
        let text = """
        diff --git a/src/app.swift b/src/app.swift
        index 1111111..2222222 100644
        --- a/src/app.swift
        +++ b/src/app.swift
        @@ -1,4 +1,5 @@ struct App {
         line one
        -line two
        +line 2
        +line 2b
         line three
         line four

        """
        let files = try DiffParser.parse(text)
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.oldPath == "src/app.swift" && file.newPath == "src/app.swift")
        #expect(file.change == .modified)
        #expect(file.oldMode == "100644" && file.newMode == "100644")
        #expect(file.additions == 2 && file.deletions == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -1,4 +1,5 @@ struct App {")
        #expect(hunk.section == "struct App {")
        #expect(hunk.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(hunk.lines[1] == DiffLine(kind: .deletion, text: "line two", oldLineNumber: 2))
        #expect(hunk.lines[3] == DiffLine(kind: .addition, text: "line 2b", newLineNumber: 3))
        #expect(hunk.lines[5] == DiffLine(kind: .context, text: "line four", oldLineNumber: 4, newLineNumber: 5))
    }

    @Test func parsesAddedDeletedAndNoNewline() throws {
        let text = """
        diff --git a/new file.txt b/new file.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new file.txt
        @@ -0,0 +1 @@
        +hello
        \\ No newline at end of file
        diff --git a/old.txt b/old.txt
        deleted file mode 100755
        index 4444444..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -a
        -b

        """
        let files = try DiffParser.parse(text)
        #expect(files.count == 2)
        #expect(files[0].change == .added && files[0].oldPath == nil && files[0].newPath == "new file.txt")
        #expect(files[0].newMode == "100644")
        #expect(files[0].hunks[0].lines.map(\.kind) == [.addition, .noNewlineAtEnd])
        #expect(files[0].hunks[0].header == "@@ -0,0 +1 @@")
        #expect(files[1].change == .deleted && files[1].newPath == nil && files[1].oldPath == "old.txt")
        #expect(files[1].oldMode == "100755")
        #expect(files[1].path == "old.txt")
        #expect(files[1].deletions == 2)
    }

    @Test func parsesRenameCopyModeChangeAndBinary() throws {
        let text = """
        diff --git a/a.txt b/b.txt
        similarity index 90%
        rename from a.txt
        rename to b.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/src.txt b/dst.txt
        similarity index 100%
        copy from src.txt
        copy to dst.txt
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/logo.png b/logo.png
        index 5..6 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let files = try DiffParser.parse(text)
        #expect(files.count == 4)
        #expect(files[0].change == .renamed(similarity: 90))
        #expect(files[0].oldPath == "a.txt" && files[0].newPath == "b.txt")
        #expect(files[1].change == .copied(similarity: 100))
        #expect(files[1].oldPath == "src.txt" && files[1].newPath == "dst.txt")
        #expect(files[2].oldMode == "100644" && files[2].newMode == "100755" && files[2].hunks.isEmpty)
        #expect(files[3].isBinary && files[3].path == "logo.png")
    }

    @Test func handlesQuotedAndSpacedHeaders() throws {
        #expect(DiffParser.splitGitHeader("a/with space.txt b/with space.txt")! == ("with space.txt", "with space.txt"))
        #expect(DiffParser.splitGitHeader("\"a/tab\\there\" \"b/tab\\there\"")! == ("tab\there", "tab\there"))
        #expect(DiffParser.splitGitHeader("a/plain \"b/tab\\tx\"")! == ("plain", "tab\tx"))
        #expect(DiffParser.splitGitHeader("a/one b/two")! == ("one", "two"))
        #expect(DiffParser.splitGitHeader("\"a/unterminated") == nil)
        #expect(DiffParser.splitGitHeader("nonsense") == nil)
    }

    @Test func contentLinesThatLookLikeHeadersStayContent() throws {
        let text = """
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,2 @@
        -diff --git a/x b/x
        +@@ -1 +1 @@
         --- a/keep

        """
        let file = try #require(try DiffParser.parse(text).first)
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].lines.map(\.text) == ["diff --git a/x b/x", "@@ -1 +1 @@", "--- a/keep"])
    }

    @Test func parsesMultipleHunksAndStrippedEmptyContext() throws {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n\n-a\n+b\n@@ -10 +10 @@ func x()\n-c\n+d\n"
        let file = try #require(try DiffParser.parse(text).first)
        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].lines.first == DiffLine(kind: .context, text: "", oldLineNumber: 1, newLineNumber: 1))
        #expect(file.hunks[1].oldStart == 10 && file.hunks[1].oldCount == 1)
        #expect(file.hunks[1].section == "func x()")
    }

    @Test func emptyDiffHasNoFiles() throws {
        #expect(try DiffParser.parse("").isEmpty)
        #expect(try DiffParser.parse(Data()).isEmpty)
    }

    @Test func rejectsBadHunks() {
        #expect(throws: GitError.self) { try DiffParser.parse("diff --git a/f b/f\n@@ nonsense @@\n") }
        #expect(throws: GitError.self) { try DiffParser.parse("diff --git a/f b/f\n@@ -1 +1 @@\n*weird\n") }
        #expect(throws: GitError.self) { try DiffParser.parse("@@ -1 +1 @@\n") }
    }

    @Test(arguments: ["@@ -1 +1 @@", "@@ -1,0 +2,3 @@", "@@ -5,2 +5,2 @@ section text"])
    func hunkHeadersRoundTrip(_ header: String) throws {
        #expect(try #require(DiffParser.parseHunkHeader(header)).header == header)
    }
}
