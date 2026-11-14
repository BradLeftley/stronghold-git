import Foundation
import GitEngine

/// A Git runner isolated from the machine's global and system config, so tests behave the same everywhere.
public enum TestGit {
    public static func runner(home: URL) throws -> GitRunner {
        guard let git = GitLocator.locate() else { throw GitError.gitNotFound }
        return GitRunner(executableURL: git, environment: [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test Author",
            "GIT_AUTHOR_EMAIL": "author@example.com",
            "GIT_COMMITTER_NAME": "Test Committer",
            "GIT_COMMITTER_EMAIL": "committer@example.com",
        ])
    }
}

/// A throwaway repository in a temporary folder, deleted when the object is released.
///
/// Commits made through `commit(_:files:)` get fixed, increasing timestamps so history is deterministic.
public final class TemporaryRepository: @unchecked Sendable {
    /// The temporary folder holding the repository (and a fake HOME next to it).
    public let baseURL: URL
    public let repository: Repository
    public var url: URL { repository.rootURL }
    public var git: GitRunner { repository.git }
    private var clock: Int = 1_767_225_600 // 2026-01-01T00:00:00Z
    private let lock = NSLock()

    public init(initialBranch: String = "main", bare: Bool = false) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("stronghold-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let home = base.appendingPathComponent("home", isDirectory: true)
        let work = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        baseURL = base
        let runner = try TestGit.runner(home: home)
        if bare {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await runner.run(["init", "--quiet", "--bare", "--initial-branch=\(initialBranch)"], in: work).checked()
            repository = Repository(rootURL: work, git: runner)
        } else {
            repository = try await Repository.initialize(at: work, initialBranch: initialBranch, git: runner)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: baseURL)
    }

    /// The canonical path of the work tree (macOS's /var → /private/var resolved).
    public var path: String { url.path }

    /// Writes a file relative to the work tree, creating folders as needed.
    public func write(_ relativePath: String, _ contents: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    public func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    public func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(relativePath))
    }

    /// Runs raw git in the work tree with the next deterministic timestamp, for setting up fixtures.
    @discardableResult
    public func git(_ arguments: String...) async throws -> String {
        try await git(arguments)
    }

    @discardableResult
    public func git(_ arguments: [String], input: Data? = nil) async throws -> String {
        try await git(arguments, input: input, date: nextDate())
    }

    private func git(_ arguments: [String], input: Data?, date: String) async throws -> String {
        var runner = repository.git
        runner.environment["GIT_AUTHOR_DATE"] = date
        runner.environment["GIT_COMMITTER_DATE"] = date
        return try await runner.run(arguments, in: url, input: input).checked().stdoutString
    }

    /// Writes `files`, stages everything and commits. Returns the new commit ID.
    @discardableResult
    public func commit(_ message: String, files: [String: String] = [:]) async throws -> String {
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) { try write(path, contents) }
        let date = nextDate()
        try await git(["add", "--all"], input: nil, date: date)
        try await git(["commit", "--quiet", "--allow-empty", "--file=-"], input: Data(message.utf8), date: date)
        return try await git(["rev-parse", "HEAD"], input: nil, date: date).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextDate() -> String {
        lock.withLock {
            clock += 60
            return "@\(clock) +0000"
        }
    }

    /// The Unix time the next fixture commit will get.
    public var nextCommitTime: Int { lock.withLock { clock + 60 } }
}

/// A bare "server" repository with a working repository that has it as `origin`, for testing fetch, pull
/// and push without a network.
public struct TemporaryRemotePair: Sendable {
    public let origin: TemporaryRepository
    public let local: TemporaryRepository

    /// `seed` makes an initial commit on `main` in `local` and pushes it, so both sides start in sync.
    public init(seed: Bool = true) async throws {
        origin = try await TemporaryRepository(bare: true)
        local = try await TemporaryRepository()
        try await local.git("remote", "add", "origin", origin.path)
        if seed {
            try await local.commit("first", files: ["a.txt": "one\n"])
            try await local.git("push", "--set-upstream", "origin", "main")
        }
    }

    /// Another working copy of the same remote, as a teammate would have.
    public func makeTeammate() async throws -> TemporaryRepository {
        let other = try await TemporaryRepository()
        try await other.git("remote", "add", "origin", origin.path)
        try await other.git("fetch", "origin")
        try await other.git("checkout", "-B", "main", "--track", "origin/main")
        return other
    }
}
