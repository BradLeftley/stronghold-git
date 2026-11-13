import Foundation
import Testing
@testable import GitEngine

@Suite("Log, ref and remote parsers")
struct OtherParserTests {
    @Test func parsesLogRecords() throws {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let records = [
            [a, "\(b) \(c)", "Ann", "ann@x", "100", "Cat", "cat@x", "200", "HEAD -> refs/heads/main, tag: refs/tags/v1", "Merge\n\nDetails\nhere\n"],
            [b, "", "Bob", "bob@x", "50", "Bob", "bob@x", "60", "", "Root\n"],
        ]
        let data = Data(records.map { $0.joined(separator: "\0") + "\0" }.joined().utf8)
        let commits = try LogParser.parse(data)
        #expect(commits.count == 2)
        #expect(commits[0].parents == [b, c])
        #expect(commits[0].isMerge)
        #expect(commits[0].author == Signature(name: "Ann", email: "ann@x", date: Date(timeIntervalSince1970: 100)))
        #expect(commits[0].committer.date == Date(timeIntervalSince1970: 200))
        #expect(commits[0].summary == "Merge")
        #expect(commits[0].body == "Details\nhere")
        #expect(commits[0].decorations == [Decoration(kind: .localBranch, fullName: "refs/heads/main", isHead: true),
                                           Decoration(kind: .tag, fullName: "refs/tags/v1")])
        #expect(commits[0].shortID == "aaaaaaa")
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].body == "")
        #expect(commits[1].decorations.isEmpty)
    }

    @Test func parsesFullDecorations() {
        let cases: [(String, Decoration.Kind, String, Bool, String)] = [
            ("HEAD -> refs/heads/feature/x", .localBranch, "refs/heads/feature/x", true, "feature/x"),
            ("HEAD", .detachedHead, "HEAD", true, "HEAD"),
            ("refs/heads/feature/x", .localBranch, "refs/heads/feature/x", false, "feature/x"),
            ("refs/remotes/origin/main", .remoteBranch, "refs/remotes/origin/main", false, "origin/main"),
            ("refs/remotes/origin/HEAD", .remoteBranch, "refs/remotes/origin/HEAD", false, "origin/HEAD"),
            ("tag: refs/tags/v1.0", .tag, "refs/tags/v1.0", false, "v1.0"),
            ("refs/stash", .other, "refs/stash", false, "refs/stash"),
        ]
        for (text, kind, fullName, isHead, name) in cases {
            let decoration = Decoration(parsing: text)
            #expect(decoration.kind == kind, "\(text)")
            #expect(decoration.fullName == fullName, "\(text)")
            #expect(decoration.isHead == isHead, "\(text)")
            #expect(decoration.name == name, "\(text)")
        }
    }

    @Test func logRejectsTruncatedOutput() {
        #expect(throws: GitError.self) { try LogParser.parse(Data("abc\0def\0".utf8)) }
        let bad = (["short"] + Array(repeating: "x", count: 9)).joined(separator: "\0") + "\0"
        #expect(throws: GitError.self) { try LogParser.parse(Data(bad.utf8)) }
    }

    @Test func parsesRefs() throws {
        let lines = [
            ["refs/heads/main", "aaa", "", "refs/remotes/origin/main", "ahead 2, behind 1", "*", ""],
            ["refs/heads/old", "bbb", "", "refs/remotes/origin/old", "gone", " ", ""],
            ["refs/remotes/origin/HEAD", "aaa", "", "", "", " ", "refs/remotes/origin/main"],
            ["refs/remotes/my-fork/topic/x", "ccc", "", "", "", " ", ""],
            ["refs/tags/v1.0", "ddd", "aaa", "", "", " ", ""],
            ["refs/notes/commits", "eee", "", "", "", " ", ""],
        ]
        let refs = try RefParser.parse(Data(lines.map { $0.joined(separator: "\0") }.joined(separator: "\n").utf8 + [10]))
        #expect(refs.count == 6)
        #expect(refs[0].kind == .localBranch && refs[0].isHead && refs[0].ahead == 2 && refs[0].behind == 1)
        #expect(refs[0].shortName == "main")
        #expect(refs[1].upstreamGone && !refs[1].isHead)
        #expect(refs[2].symbolicTarget == "refs/remotes/origin/main")
        #expect(refs[3].kind == .remoteBranch(remote: "my-fork"))
        #expect(refs[3].shortName == "my-fork/topic/x")
        #expect(refs[4].kind == .tag && refs[4].commitID == "aaa" && refs[4].target == "ddd")
        #expect(refs[5].kind == .other && refs[5].shortName == "refs/notes/commits")
    }

    @Test func refParserRejectsWrongFieldCount() {
        #expect(throws: GitError.self) { try RefParser.parse(Data("refs/heads/x\0abc\n".utf8)) }
    }

    @Test func parsesTrackingText() {
        #expect(RefParser.parseTrack("") == (0, 0, false))
        #expect(RefParser.parseTrack("ahead 5") == (5, 0, false))
        #expect(RefParser.parseTrack("behind 7") == (0, 7, false))
        #expect(RefParser.parseTrack("gone") == (0, 0, true))
    }

    @Test func parsesRemotesIncludingDottedNamesAndPushURLs() {
        let entries = [
            "remote.origin.url\nhttps://github.com/a/b.git",
            "remote.origin.pushurl\ngit@github.com:a/b.git",
            "remote.origin.pushurl\ngit@gitlab.com:a/b.git",
            "remote.my.dotted.url\n/tmp/repo",
            "remote.fetchonly.fetch\n+refs/heads/*:refs/remotes/fetchonly/*",
            "remote..url\nbroken",
            "remote.novalue.url",
        ]
        let remotes = RemoteParser.parse(Data((entries.joined(separator: "\0") + "\0").utf8))
        #expect(remotes.map(\.name) == ["origin", "my.dotted", "novalue"])
        #expect(remotes[0].fetchURL == "https://github.com/a/b.git")
        #expect(remotes[0].pushURLs == ["git@github.com:a/b.git", "git@gitlab.com:a/b.git"])
        #expect(remotes[0].effectivePushURL == "git@github.com:a/b.git")
        #expect(remotes[1].effectivePushURL == "/tmp/repo")
        #expect(remotes[2].fetchURL == "")
    }

    @Test(arguments: [
        ("git version 2.54.0 (Apple Git-157)", GitVersion(major: 2, minor: 54, patch: 0), "(Apple Git-157)"),
        ("git version 2.39.5\n", GitVersion(major: 2, minor: 39, patch: 5), ""),
        ("git version 2.45.1.windows.1", GitVersion(major: 2, minor: 45, patch: 1), ".windows.1"),
        ("git version 2.40", GitVersion(major: 2, minor: 40, patch: 0), ""),
        ("git version 2.41.rc0", GitVersion(major: 2, minor: 41, patch: 0), ".rc0"),
    ])
    func parsesVersions(_ text: String, _ expected: GitVersion, _ suffix: String) throws {
        let version = try #require(GitVersion(parsing: text))
        #expect(version == expected)
        #expect(version.suffix == suffix)
    }

    @Test func versionsCompareAndRejectGarbage() {
        #expect(GitVersion(parsing: "hello") == nil)
        #expect(GitVersion(parsing: "git version x.y") == nil)
        #expect(GitVersion(major: 2, minor: 30, patch: 9) < GitVersion.minimumSupported)
        #expect(GitVersion(major: 3, minor: 0, patch: 0) > GitVersion.minimumSupported)
        #expect(GitVersion.minimumSupported.description == "2.35.0")
    }

    @Test(arguments: [
        ("plain", "plain"),
        ("\"tab\\there\"", "tab\there"),
        ("\"caf\\303\\251\"", "café"),
        ("\"q\\\"uote\\\\\"", "q\"uote\\"),
        ("\"nl\\nx\\r\\a\\b\\f\\v\"", "nl\nx\r\u{07}\u{08}\u{0C}\u{0B}"),
        ("\"", "\""),
    ])
    func unquotesPaths(_ quoted: String, _ expected: String) {
        #expect(GitPathUnquoter.unquote(quoted[...]) == expected)
    }

    @Test func nulFieldsKeepInnerEmptyFields() {
        #expect(Data("a\0\0b\0".utf8).nulSeparatedFields() == ["a", "", "b"])
        #expect(Data().nulSeparatedFields() == [])
        #expect(Data("a".utf8).nulSeparatedFields() == ["a"])
    }

    @Test func errorsHaveReadableDescriptions() {
        let failed = GitError.commandFailed(arguments: ["push", "origin", "main"], exitCode: 128, stderr: "fatal: nope\n")
        #expect(failed.errorDescription == "fatal: nope")
        let silent = GitError.commandFailed(arguments: ["push", "origin", "main"], exitCode: 1, stderr: "")
        #expect(silent.errorDescription == "git push origin failed with exit code 1.")
        #expect(GitError.gitNotFound.errorDescription?.contains("Command Line Tools") == true)
        #expect(GitError.notARepository(URL(fileURLWithPath: "/tmp/x")).errorDescription == "/tmp/x is not a Git repository.")
        #expect(GitError.launchFailed("boom").errorDescription?.contains("boom") == true)
        #expect(GitError.unexpectedOutput("odd").errorDescription?.contains("odd") == true)
        #expect(GitError.unsupportedVersion(GitVersion(major: 2, minor: 1, patch: 0)).errorDescription?.contains("2.35.0") == true)
    }
}
