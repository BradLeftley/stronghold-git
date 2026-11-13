import Foundation
import Testing
@testable import GitEngine
import GitTestSupport

@Suite("Git runner and locator")
struct RunnerTests {
    private func runner() throws -> GitRunner {
        try TestGit.runner(home: FileManager.default.temporaryDirectory)
    }

    @Test func reportsAnInstalledSupportedVersion() async throws {
        let version = try await runner().version()
        #expect(version >= GitVersion.minimumSupported)
    }

    @Test func nonZeroExitIsReturnedThenThrownByChecked() async throws {
        let result = try await runner().run(["rev-parse", "--verify", "no-such-ref"], in: FileManager.default.temporaryDirectory)
        #expect(!result.succeeded)
        #expect(result.exitCode != 0)
        #expect(throws: GitError.self) { try result.checked() }
    }

    @Test func passesStandardInput() async throws {
        let result = try await runner().run(["hash-object", "--stdin"], in: nil, input: Data("hello\n".utf8)).checked()
        #expect(result.stdoutString == "ce013625030ba8dba906f756967f9e9ca394464a\n")
    }

    @Test func handlesLargeOutputOnBothPipesWithoutDeadlock() async throws {
        // 4 MB through stdin and back out through stdout via `git hash-object`'s sibling, `cat-file`.
        let tmp = try await TemporaryRepository()
        let blob = String(repeating: "0123456789abcdef", count: 262_144)
        let id = try await tmp.git(["hash-object", "-w", "--stdin"], input: Data(blob.utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await tmp.repository.run(["cat-file", "blob", id])
        #expect(result.stdout.count == blob.utf8.count)
    }

    @Test func appliesSafeDefaultsAndRemovesRepositoryOverrides() throws {
        let runner = GitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/git"), environment: ["EXTRA": "1", "LC_ALL": "en_GB"])
        let env = runner.processEnvironment()
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_PAGER"] == "cat")
        #expect(env["EXTRA"] == "1")
        #expect(env["LC_ALL"] == "en_GB", "explicit environment wins over defaults")
        #expect(env["GIT_DIR"] == nil)
        let args = runner.fullArguments(["status"])
        #expect(args.last == "status")
        #expect(args.contains("core.quotepath=false"))
        #expect(args.contains("color.ui=false"))
    }

    @Test func environmentReachesTheChildProcess() async throws {
        let env = GitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/env"), environment: ["STRONGHOLD_TEST": "yes"],
                            configOverrides: [:])
        let output = try await env.run([], in: nil).checked().stdoutString
        #expect(output.contains("STRONGHOLD_TEST=yes"))
        #expect(output.contains("GIT_TERMINAL_PROMPT=0"))
    }

    @Test func launchFailureThrows() async {
        let missing = GitRunner(executableURL: URL(fileURLWithPath: "/nonexistent/git"))
        await #expect(throws: GitError.self) { try await missing.run(["--version"], in: nil) }
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let sleeper = GitRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), configOverrides: [:])
        let start = Date()
        let task = Task { try await sleeper.run(["30"], in: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func alreadyCancelledTaskNeverStartsTheProcess() async {
        let sleeper = GitRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), configOverrides: [:])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sleeper.run(["30"], in: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func locatorPrefersExplicitPathsAndSkipsMissingOnes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fake = tmp.appendingPathComponent("git")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let notExecutable = tmp.appendingPathComponent("plain")
        try Data().write(to: notExecutable)

        #expect(GitLocator.locate(preferredPath: fake.path, environment: [:], candidates: [])?.path == fake.path)
        #expect(GitLocator.locate(environment: ["STRONGHOLD_GIT": fake.path], candidates: [])?.path == fake.path)
        #expect(GitLocator.locate(preferredPath: "/missing", environment: [:], candidates: [tmp.path, notExecutable.path, fake.path])?.path == fake.path)
        #expect(GitLocator.locate(environment: [:], candidates: ["", "/missing"]) == nil)
        #expect(GitLocator.locate() != nil, "a git must be installed to run these tests")
        #expect(GitRunner.system() != nil)
    }
}
