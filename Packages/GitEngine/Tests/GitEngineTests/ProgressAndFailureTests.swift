import Foundation
import Testing
@testable import GitEngine

@Suite("Progress and failure parsing")
struct ProgressAndFailureTests {
    // MARK: Progress

    @Test func parsesPlainProgress() {
        let p = ProgressParser.parse("Receiving objects:  45% (45/100), 1.20 MiB | 1.00 MiB/s")
        #expect(p == TransferProgress(phase: "Receiving objects", percent: 45, current: 45, total: 100,
                                      detail: "1.20 MiB | 1.00 MiB/s"))
        #expect(p?.fraction == 0.45)
        #expect(p?.summary == "Receiving objects 45% · 1.20 MiB | 1.00 MiB/s")
    }

    @Test func parsesRemoteAndFinishedLines() {
        #expect(ProgressParser.parse("remote: Counting objects: 100% (5/5), done.")
                == TransferProgress(phase: "Counting objects", percent: 100, current: 5, total: 5))
        #expect(ProgressParser.parse("Resolving deltas: 100% (3/3), done.")?.detail == "")
        #expect(ProgressParser.parse("Writing objects: 100% (3/3), 250 bytes | 250.00 KiB/s, done.")?.detail
                == "250 bytes | 250.00 KiB/s")
    }

    @Test(arguments: ["", "From /tmp/repo", " * [new branch]      main       -> origin/main",
                      "error: failed to push some refs to 'x'", "remote: Create a pull request: https://x/y",
                      "Receiving objects: nan% (a/b)", "Total 3 (delta 0), reused 0 (delta 0)"])
    func ignoresOtherLines(line: String) {
        #expect(ProgressParser.parse(line) == nil)
    }

    // MARK: Classification

    @Test(arguments: [
        ("fatal: Authentication failed for 'https://github.com/a/b.git/'", RemoteFailure.authenticationFailed),
        ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", .authenticationFailed),
        ("remote: Invalid username or password.", .authenticationFailed),
        ("remote: Support for password authentication was removed on August 13, 2021.", .authenticationFailed),
        ("Host key verification failed.\nfatal: Could not read from remote repository.", .sshFailed),
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .sshFailed),
        ("remote: Repository not found.\nfatal: repository 'https://x/y.git/' not found", .repositoryNotFound),
        ("fatal: '/tmp/x' does not appear to be a git repository\nfatal: Could not read from remote repository.", .repositoryNotFound),
        ("fatal: unable to access 'https://x/': Could not resolve host: x", .hostUnreachable),
        ("ssh: Could not resolve hostname x: nodename nor servname provided\nfatal: Could not read from remote repository.", .hostUnreachable),
        ("fatal: unable to access 'https://x/': Connection timed out after 300000 milliseconds", .hostUnreachable),
        ("! [rejected]        main -> main (fetch first)\nerror: failed to push some refs", .pushRejectedNonFastForward),
        ("! [rejected]        main -> main (non-fast-forward)", .pushRejectedNonFastForward),
        ("! [remote rejected] main -> main (protected branch hook declined)", .pushDeclined),
        ("remote: error: GH006: Protected branch update failed", .pushDeclined),
        ("! [rejected]        main -> main (stale info)", .staleInfo),
        ("There is no tracking information for the current branch.", .noUpstream),
        ("fatal: The current branch x has no upstream branch.", .noUpstream),
        ("fatal: No configured push destination.", .noRemote),
        ("fatal: Not possible to fast-forward, aborting.", .cannotFastForward),
        ("CONFLICT (content): Merge conflict in a.txt\nAutomatic merge failed; fix conflicts", .mergeConflict),
        ("error: Your local changes to the following files would be overwritten by merge:\n\ta.txt", .localChangesInTheWay),
        ("something unforeseen", .other),
    ])
    func classifiesGitMessages(output: String, expected: RemoteFailure) {
        #expect(RemoteFailure.classify(output) == expected)
    }

    @Test func everyKnownFailureHasAdviceExceptOther() {
        let all: [RemoteFailure] = [.authenticationFailed, .repositoryNotFound, .hostUnreachable, .sshFailed,
                                    .pushRejectedNonFastForward, .pushDeclined, .staleInfo, .noUpstream, .noRemote,
                                    .mergeConflict, .cannotFastForward, .localChangesInTheWay]
        for failure in all { #expect(failure.advice?.isEmpty == false) }
        #expect(RemoteFailure.other.advice == nil)
    }

    @Test func errorDescriptionCombinesAdviceAndGitsMessage() {
        let error = GitError.remoteFailed(.hostUnreachable, detail: "fatal: unable to access 'x'")
        #expect(error.localizedDescription.contains("Check your internet connection"))
        #expect(error.localizedDescription.contains("unable to access"))
        #expect(GitError.remoteFailed(.other, detail: "boom").localizedDescription == "boom")
        #expect(GitError.remoteFailed(.other, detail: "").localizedDescription == "The remote operation failed.")
    }

    // MARK: Redaction

    @Test func redactsCredentialsInURLs() {
        #expect(Redactor.redact("fatal: unable to access 'https://user:ghp_secret@github.com/a/b.git/': 403")
                == "fatal: unable to access 'https://***@github.com/a/b.git/': 403")
        #expect(Redactor.redact("https://token@host/x and https://u:p@other/y")
                == "https://***@host/x and https://***@other/y")
        #expect(Redactor.redact("git@github.com:a/b.git") == "git@github.com:a/b.git")
        #expect(Redactor.redact("https://github.com/a/b/issues/@me") == "https://github.com/a/b/issues/@me")
        #expect(Redactor.redact("plain text") == "plain text")
    }

    @Test func failureMessagesNeverCarryTokens() async throws {
        // A real failing run against an address with embedded credentials.
        let runner = try #require(GitRunner.system())
        let result = try await runner.run(["ls-remote", "--", "file:///nonexistent-stronghold-test"], in: nil)
        #expect(!result.succeeded)
        let checked = Result { try result.checked() }
        if case .failure(let error) = checked { #expect(!error.localizedDescription.contains("ghp_")) }
        let credentialed = GitCommandResult(arguments: ["fetch", "https://u:ghp_abc@host/r"], exitCode: 128, stdout: Data(),
                                            stderr: Data("fatal: unable to access 'https://u:ghp_abc@host/r/'".utf8))
        do { try credentialed.checked() } catch {
            #expect(!error.localizedDescription.contains("ghp_abc"))
        }
    }
}
