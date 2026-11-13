import Foundation

extension Repository {
    /// The files `commit` changed compared with its first parent (or with nothing, for a root commit).
    public func changedFiles(in commit: Commit) async throws -> [CommitFileChange] {
        let base = commit.parents.first ?? Self.emptyTreeID
        let result = try await run(["diff-tree", "-r", "-z", "-M", "--name-status", "--no-ext-diff",
                                    "--end-of-options", base, commit.id, "--"])
        return try NameStatusParser.parse(result.stdout)
    }

    /// How `commit` changed one file, compared with its first parent. Pass the change from
    /// `changedFiles(in:)` so a renamed file is paired with its old name.
    public func diff(of change: CommitFileChange, in commit: Commit, contextLines: Int = 3) async throws -> FileDiff? {
        let base = commit.parents.first ?? Self.emptyTreeID
        let files = try await diff(.range(from: base, to: commit.id), paths: change.pathspec, contextLines: contextLines)
        return files.first { $0.newPath == change.path || $0.oldPath == change.path } ?? files.first
    }

    /// The commits that changed `path`, newest first, following it back through renames.
    /// - Parameter revision: where to start; nil means HEAD.
    public func fileHistory(of path: String, from revision: String? = nil, limit: Int? = nil) async throws -> [FileHistoryEntry] {
        if revision == nil, try await resolve("HEAD") == nil { return [] }
        var arguments = ["log", "-z", "--format=\(LogParser.format)", "--no-show-signature", "--no-color",
                         "--follow", "--name-status", "-M"]
        if let limit { arguments.append("--max-count=\(limit)") }
        arguments += ["--end-of-options", revision ?? "HEAD", "--", path]
        return try FileHistoryParser.parse(try await run(arguments).stdout, path: path)
    }

    /// Who last changed each line of `path`.
    /// - Parameter revision: the commit to blame at; nil blames the file in the work tree, including
    ///   uncommitted lines.
    public func blame(_ path: String, at revision: String? = nil) async throws -> Blame {
        var arguments = ["blame", "--porcelain", "-M", "--no-progress"]
        if let revision {
            // blame reads `--` as a revision after `--end-of-options`, so resolve the revision to an
            // object ID first: an ID can never be taken for an option.
            guard let id = try await resolve(revision) else {
                throw GitError.unexpectedOutput("no commit for \(revision)")
            }
            arguments.append(id)
        }
        arguments += ["--", path]
        return try BlameParser.parse(try await run(arguments).stdout, path: path)
    }
}
