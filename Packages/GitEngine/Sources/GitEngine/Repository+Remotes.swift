import Foundation

public enum PullStrategy: Sendable, Equatable, CaseIterable {
    /// Fast-forward when possible, otherwise make a merge commit.
    case merge
    /// Replay local commits on top of the remote ones.
    case rebase
    /// Refuse unless a fast-forward is possible.
    case fastForwardOnly
}

public struct FetchOptions: Sendable, Equatable {
    /// One remote, or nil for all of them.
    public var remote: String?
    /// Delete remote-tracking branches that no longer exist on the remote.
    public var prune: Bool
    public var tags: Bool

    public init(remote: String? = nil, prune: Bool = true, tags: Bool = false) {
        self.remote = remote
        self.prune = prune
        self.tags = tags
    }
}

public struct PullOptions: Sendable, Equatable {
    public var strategy: PullStrategy
    /// Stash local changes first and reapply them afterwards.
    public var autostash: Bool

    public init(strategy: PullStrategy = .merge, autostash: Bool = false) {
        self.strategy = strategy
        self.autostash = autostash
    }
}

public struct PushOptions: Sendable, Equatable {
    /// The remote to push to; ignored when the branch already has an upstream. Defaults to `origin`, or the
    /// only remote.
    public var remote: String?
    /// Make the branch track the remote branch. Always done when it has no upstream yet.
    public var setUpstream: Bool
    /// Overwrite the remote branch, but only if nobody else has pushed to it since your last fetch.
    public var forceWithLease: Bool
    /// Also push annotated tags that point at the pushed commits.
    public var followTags: Bool

    public init(remote: String? = nil, setUpstream: Bool = false, forceWithLease: Bool = false, followTags: Bool = false) {
        self.remote = remote
        self.setUpstream = setUpstream
        self.forceWithLease = forceWithLease
        self.followTags = followTags
    }
}

public struct PullResult: Sendable, Equatable {
    public var alreadyUpToDate: Bool
}

public struct PushResult: Sendable, Equatable {
    public var remote: String
    public var branch: String
    public var setUpstream: Bool
    public var alreadyUpToDate: Bool
}

/// Fetch, pull and push. Each takes a progress callback, is cancellable by cancelling its task, and turns
/// git's failures into `GitError.remoteFailed` with a plain-language explanation.
extension Repository {
    public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

    // MARK: Fetch

    public func fetch(_ options: FetchOptions = FetchOptions(), onProgress: ProgressHandler? = nil) async throws {
        var arguments = ["fetch", "--progress", "--no-recurse-submodules"]
        if options.prune { arguments.append("--prune") }
        if options.tags { arguments.append("--tags") }
        if let remote = options.remote {
            arguments += ["--", remote]
        } else {
            arguments.insert("--all", at: 1)
        }
        if options.remote == nil, try await remotes().isEmpty { throw GitError.remoteFailed(.noRemote, detail: "") }
        _ = try await runNetwork(arguments, onProgress: onProgress)
    }

    // MARK: Pull

    /// The strategy the user's git config asks for (`pull.rebase`, `pull.ff`), defaulting to merge.
    public func defaultPullStrategy() async throws -> PullStrategy {
        if let rebase = try await config("pull.rebase"), ["true", "merges", "interactive", "yes", "on", "1"].contains(rebase.lowercased()) {
            return .rebase
        }
        if try await config("pull.ff")?.lowercased() == "only" { return .fastForwardOnly }
        return .merge
    }

    /// Pulls the current branch from its upstream.
    @discardableResult
    public func pull(_ options: PullOptions = PullOptions(), onProgress: ProgressHandler? = nil) async throws -> PullResult {
        guard try await currentBranch() != nil else {
            throw GitError.remoteFailed(.noUpstream, detail: "HEAD is detached, so there is no branch to pull into.")
        }
        var arguments = ["pull", "--progress", "--no-edit", "--no-recurse-submodules"]
        switch options.strategy {
        case .merge: arguments.append("--no-rebase")
        case .rebase: arguments.append("--rebase")
        case .fastForwardOnly: arguments += ["--ff-only"]
        }
        arguments.append(options.autostash ? "--autostash" : "--no-autostash")
        let result = try await runNetwork(arguments, onProgress: onProgress)
        return PullResult(alreadyUpToDate: result.stdoutString.contains("Already up to date"))
    }

    // MARK: Push

    /// Pushes `branch` (the current branch when nil) to its upstream, or to `options.remote` and sets the
    /// upstream when it has none.
    @discardableResult
    public func push(branch: String? = nil, _ options: PushOptions = PushOptions(),
                     onProgress: ProgressHandler? = nil) async throws -> PushResult {
        let name: String
        if let branch {
            name = branch
        } else if let current = try await currentBranch() {
            name = current
        } else {
            throw GitError.remoteFailed(.other, detail: "HEAD is detached. Switch to a branch to push it.")
        }
        let configuredRemote = try await config("branch.\(name).remote")
        let configuredMerge = try await config("branch.\(name).merge")
        let hasUpstream = configuredRemote != nil && configuredMerge != nil && configuredRemote != "."

        let remote: String
        let destination: String
        if hasUpstream, let configuredRemote, let configuredMerge {
            remote = configuredRemote
            destination = configuredMerge.hasPrefix("refs/heads/") ? String(configuredMerge.dropFirst("refs/heads/".count)) : name
        } else {
            remote = try await defaultRemote(preferred: options.remote)
            destination = name
        }

        var arguments = ["push", "--progress"]
        let settingUpstream = options.setUpstream || !hasUpstream
        if settingUpstream { arguments.append("--set-upstream") }
        if options.forceWithLease { arguments.append("--force-with-lease") }
        if options.followTags { arguments.append("--follow-tags") }
        arguments += ["--", remote, "refs/heads/\(name):refs/heads/\(destination)"]
        let result = try await runNetwork(arguments, onProgress: onProgress)
        return PushResult(remote: remote, branch: destination, setUpstream: settingUpstream,
                          alreadyUpToDate: (result.stderrString + result.stdoutString).contains("Everything up-to-date"))
    }

    /// Deletes a branch on the remote.
    public func deleteRemoteBranch(remote: String, branch: String, onProgress: ProgressHandler? = nil) async throws {
        try await validateBranchName(branch)
        _ = try await runNetwork(["push", "--progress", "--delete", "--", remote, "refs/heads/\(branch)"], onProgress: onProgress)
    }

    /// `preferred`, else `origin`, else the only remote.
    func defaultRemote(preferred: String?) async throws -> String {
        let names = try await remotes().map(\.name)
        if let preferred {
            guard names.contains(preferred) else { throw GitError.remoteFailed(.noRemote, detail: "There is no remote called \(preferred).") }
            return preferred
        }
        if names.contains("origin") { return "origin" }
        if names.count == 1, let only = names.first { return only }
        throw GitError.remoteFailed(.noRemote, detail: names.isEmpty ? "" : "Choose which remote to push to: \(names.joined(separator: ", ")).")
    }

    // MARK: Running

    /// Runs a network command: limits transports, keeps SSH from prompting, streams progress, and classifies
    /// failures. Credentials in git's output are removed.
    func runNetwork(_ arguments: [String], onProgress: ProgressHandler?) async throws -> GitCommandResult {
        var runner = git
        runner.environment["GIT_ALLOW_PROTOCOL"] = Self.cloneProtocols
        // With no terminal ssh could wait forever for a passphrase or host-key answer. Fail instead, unless the
        // user has configured their own ssh command.
        var hasCustomSSH = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] != nil
            || ProcessInfo.processInfo.environment["GIT_SSH"] != nil
            || git.environment["GIT_SSH_COMMAND"] != nil
        if !hasCustomSSH, try await config("core.sshCommand") != nil { hasCustomSSH = true }
        if !hasCustomSSH { runner.environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }

        var handler: (@Sendable (String) -> Void)?
        if let onProgress {
            handler = { line in
                if let progress = ProgressParser.parse(Redactor.redact(line)) { onProgress(progress) }
            }
        }
        let result = try await runner.run(arguments, in: rootURL, onStandardError: handler)
        guard result.succeeded else {
            let detail = Redactor.redact(Self.messageLines(from: result))
            throw GitError.remoteFailed(RemoteFailure.classify(detail), detail: detail)
        }
        return result
    }

    /// Git's explanation of a failure: stderr without progress lines, plus conflict lines from stdout.
    static func messageLines(from result: GitCommandResult) -> String {
        let stderr = result.stderrString.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { ProgressParser.parse($0) == nil }
        let conflicts = result.stdoutString.split(separator: "\n").map(String.init).filter { $0.contains("CONFLICT") }
        return (conflicts + stderr).joined(separator: "\n")
    }
}
