import Foundation

/// Working-copy operations: partial staging, discarding, untracked previews and cloning.
extension Repository {
    // MARK: Previews

    /// The diff of an untracked file, shown as one all-added file. Directories (such as an untracked
    /// nested repository) have no preview and give an empty list.
    public func untrackedDiff(for path: String, contextLines: Int = 3) async throws -> [FileDiff] {
        var isDirectory: ObjCBool = false
        let location = rootURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return []
        }
        // `git diff --no-index` exits with 1 when the files differ, which is the normal case here.
        let result = try await git.run(
            ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
             "--unified=\(max(0, contextLines))", "--", "/dev/null", path],
            in: rootURL)
        guard result.exitCode == 0 || result.exitCode == 1 else { try result.checked(); return [] }
        return try DiffParser.parse(result.stdout)
    }

    // MARK: Partial changes

    /// Stages the selected lines of `file`, a diff of the unstaged changes.
    public func stageLines(of file: FileDiff, _ selection: Set<LineSelection>) async throws {
        try await applyPatch(of: file, selection, intent: .stage)
    }

    /// Removes the selected lines of `file`, a diff of the staged changes, from the index.
    public func unstageLines(of file: FileDiff, _ selection: Set<LineSelection>) async throws {
        try await applyPatch(of: file, selection, intent: .unstage)
    }

    /// Reverts the selected lines of `file`, a diff of the unstaged changes, in the work tree. This can't
    /// be undone.
    public func discardLines(of file: FileDiff, _ selection: Set<LineSelection>) async throws {
        try await applyPatch(of: file, selection, intent: .discard)
    }

    func applyPatch(of file: FileDiff, _ selection: Set<LineSelection>, intent: PatchIntent) async throws {
        guard let patch = PatchBuilder.patch(for: file, selecting: selection, intent: intent) else {
            throw GitError.unexpectedOutput("nothing to apply for \(file.path)")
        }
        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        if intent != .discard { arguments.append("--cached") }
        if intent.isReverse { arguments.append("--reverse") }
        arguments.append("-")
        try await run(arguments, input: Data(patch.utf8))
    }

    // MARK: Discarding

    /// Reverts tracked files to their staged content and deletes untracked files. This can't be undone.
    public func discardChanges(tracked: [String] = [], untracked: [String] = []) async throws {
        if !tracked.isEmpty {
            try await run(["restore", "--worktree", "--"] + tracked)
        }
        if !untracked.isEmpty {
            try await run(["clean", "--force", "--quiet", "--"] + untracked)
        }
    }

    // MARK: Commit helpers

    /// The full message of HEAD, used to pre-fill the message when amending. Nil before the first commit.
    public func headMessage() async throws -> String? {
        guard try await resolve("HEAD") != nil else { return nil }
        let result = try await run(["log", "-1", "--format=%B", "--no-show-signature", "HEAD", "--"])
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cloning

    /// The protocols a clone may use. `ext::` and other transports that run commands are left out.
    static let cloneProtocols = "file:git:http:https:ssh"

    /// Clones `remote` into `destination`, which must not exist or be empty, and opens the result.
    /// Cancelling the task stops git and removes a destination this call created.
    public static func clone(from remote: String, to destination: URL, git: GitRunner) async throws -> Repository {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { throw GitError.unexpectedOutput("no repository address given") }
        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: destination.path)
        var runner = git
        runner.environment["GIT_ALLOW_PROTOCOL"] = cloneProtocols
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await runner.run(["clone", "--quiet", "--", remote, destination.path],
                                 in: destination.deletingLastPathComponent()).checked()
            return try await open(at: destination, git: git)
        } catch {
            if !existed { try? fileManager.removeItem(at: destination) }
            throw error
        }
    }

    /// The folder name git would pick for a clone of `remote`: the last path component without `.git`.
    public static func defaultFolderName(forRemote remote: String) -> String {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        // scp-style "git@host:owner/repo" and URLs both end in the name after the last / or :.
        let name = text.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        return name.trimmingCharacters(in: .whitespaces)
    }
}
