import Foundation

/// A Git working tree and the operations Stronghold runs on it. It holds no state of its own, so it is
/// cheap to copy and safe to use from any task; every method runs `git` in the repository root.
public struct Repository: Sendable, Equatable {
    /// The top level of the working tree.
    public let rootURL: URL
    public let git: GitRunner

    public static func == (lhs: Repository, rhs: Repository) -> Bool {
        lhs.rootURL == rhs.rootURL && lhs.git.executableURL == rhs.git.executableURL
    }

    /// Opens the repository containing `url`. Throws `GitError.notARepository` if there isn't one.
    public static func open(at url: URL, git: GitRunner) async throws -> Repository {
        let result = try await git.run(["rev-parse", "--show-toplevel"], in: url)
        guard result.succeeded else {
            if result.stderrString.contains("not a git repository") || result.stderrString.contains("must be run in a work tree") {
                throw GitError.notARepository(url)
            }
            try result.checked()
            throw GitError.notARepository(url)
        }
        let top = result.stdoutString.trimmingCharacters(in: .newlines)
        guard !top.isEmpty else { throw GitError.notARepository(url) }
        return Repository(rootURL: URL(fileURLWithPath: top, isDirectory: true), git: git)
    }

    /// Creates a new repository at `url` (making the folder if needed) and opens it.
    public static func initialize(at url: URL, initialBranch: String = "main", git: GitRunner) async throws -> Repository {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await git.run(["init", "--quiet", "--initial-branch=\(initialBranch)", "--", url.path], in: url).checked()
        return try await open(at: url, git: git)
    }

    /// Creates a repository handle without checking the folder. Prefer `open(at:git:)`.
    public init(rootURL: URL, git: GitRunner) {
        self.rootURL = rootURL
        self.git = git
    }

    /// Runs git in the repository root, throwing if it fails.
    @discardableResult
    public func run(_ arguments: [String], input: Data? = nil) async throws -> GitCommandResult {
        try await git.run(arguments, in: rootURL, input: input).checked()
    }

    // MARK: - Reading

    /// The working-tree status, including branch tracking information and the stash count.
    public func status(includeUntracked: Bool = true, includeIgnored: Bool = false) async throws -> RepositoryStatus {
        var arguments = ["status", "--porcelain=v2", "--branch", "--show-stash", "-z"]
        arguments.append(includeUntracked ? "--untracked-files=all" : "--untracked-files=no")
        if includeIgnored { arguments.append("--ignored=matching") }
        return try StatusParser.parse(try await run(arguments).stdout)
    }

    /// Commits, newest first. Returns an empty list for a repository with no commits yet.
    public func log(_ query: LogQuery = LogQuery()) async throws -> [Commit] {
        if !query.allRefs, query.revisions.isEmpty, try await resolve("HEAD") == nil { return [] }
        var arguments = ["log", "-z", "--format=\(LogParser.format)", "--no-show-signature", "--no-color"]
        if query.topologicalOrder { arguments.append("--topo-order") }
        if let limit = query.limit { arguments.append("--max-count=\(limit)") }
        if query.skip > 0 { arguments.append("--skip=\(query.skip)") }
        arguments += query.filterArguments
        if query.allRefs { arguments += ["--exclude=refs/stash", "--all"] }
        arguments.append("--end-of-options")
        if !query.allRefs { arguments += query.revisions.isEmpty ? ["HEAD"] : query.revisions }
        arguments.append("--")
        arguments += query.paths
        return try LogParser.parse(try await run(arguments).stdout)
    }

    /// One commit by revision.
    public func commit(_ revision: String) async throws -> Commit {
        let commits = try await log(LogQuery(revisions: [revision], limit: 1))
        guard let commit = commits.first else { throw GitError.unexpectedOutput("no commit for \(revision)") }
        return commit
    }

    /// The object ID `revision` names, or nil if it doesn't exist.
    public func resolve(_ revision: String) async throws -> String? {
        let result = try await git.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"],
                                       in: rootURL)
        guard result.succeeded else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Branches, remote-tracking branches and tags.
    public func refs() async throws -> [Ref] {
        let result = try await run(["for-each-ref", "--format=\(RefParser.format)",
                                    "refs/heads", "refs/remotes", "refs/tags"])
        return try RefParser.parse(result.stdout)
    }

    public func localBranches() async throws -> [Ref] {
        try await refs().filter { $0.kind == .localBranch }
    }

    /// The checked-out branch name, or nil when HEAD is detached.
    public func currentBranch() async throws -> String? {
        let result = try await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: rootURL)
        guard result.succeeded else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func remotes() async throws -> [Remote] {
        let result = try await git.run(["config", "-z", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#], in: rootURL)
        // Exit code 1 means no matching keys.
        if result.exitCode == 1 { return [] }
        return RemoteParser.parse(try result.checked().stdout)
    }

    /// A config value as git resolves it (local, then global, then system), or nil if unset.
    public func config(_ key: String) async throws -> String? {
        let result = try await git.run(["config", "--get", "--end-of-options", key], in: rootURL)
        if result.exitCode == 1 { return nil }
        return try result.checked().stdoutString.trimmingCharacters(in: .newlines)
    }

    /// Sets a config value in this repository's `.git/config`.
    public func setConfig(_ key: String, to value: String) async throws {
        try await run(["config", "--local", "--end-of-options", key, value])
    }

    /// The changes for `target`, optionally limited to `paths`.
    public func diff(_ target: DiffTarget = .workTree, paths: [String] = [], contextLines: Int = 3) async throws -> [FileDiff] {
        var arguments: [String]
        let common = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/",
                      "--unified=\(max(0, contextLines))"]
        switch target {
        case .workTree:
            arguments = ["diff"] + common
        case .staged:
            arguments = ["diff", "--cached"] + common
            if try await resolve("HEAD") == nil {
                // Nothing committed yet: compare against the empty tree.
                arguments += ["--end-of-options", Self.emptyTreeID]
            }
        case .commit(let revision):
            arguments = ["show", "--format=", "--first-parent", "--no-show-signature"] + common
                + ["--end-of-options", revision]
        case .range(let from, let to):
            arguments = ["diff"] + common + ["--end-of-options", from, to]
        }
        arguments.append("--")
        arguments += paths
        return try DiffParser.parse(try await run(arguments).stdout)
    }

    /// The SHA-1 of git's empty tree.
    public static let emptyTreeID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // MARK: - Changing

    /// Stages the given paths, including deletions.
    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await run(["add", "--all", "--"] + paths)
    }

    /// Stages every change in the work tree.
    public func stageAll() async throws {
        try await run(["add", "--all"])
    }

    /// Removes the given paths from the index, keeping the work-tree files.
    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if try await resolve("HEAD") == nil {
            try await run(["rm", "--cached", "--quiet", "-r", "--ignore-unmatch", "--"] + paths)
        } else {
            try await run(["restore", "--staged", "--"] + paths)
        }
    }

    /// Commits the index and returns the new commit's ID.
    @discardableResult
    public func commit(message: String, amend: Bool = false, allowEmpty: Bool = false) async throws -> String {
        var arguments = ["commit", "--quiet", "--file=-", "--cleanup=strip"]
        if amend { arguments.append("--amend") }
        if allowEmpty { arguments.append("--allow-empty") }
        try await run(arguments, input: Data(message.utf8))
        guard let id = try await resolve("HEAD") else { throw GitError.unexpectedOutput("HEAD missing after commit") }
        return id
    }
}
