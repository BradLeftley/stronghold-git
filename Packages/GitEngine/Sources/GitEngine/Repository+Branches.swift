import Foundation

/// Rules for branch names, checked before git is asked so the UI can explain a problem as you type.
public enum BranchName {
    /// Why `name` can't be a branch name, or nil if it looks fine. Git has the final say.
    public static func problem(in name: String) -> String? {
        if name.isEmpty { return "the name is empty" }
        if name == "@" { return "\u{201C}@\u{201D} alone isn\u{2019}t allowed" }
        if name.hasPrefix("-") { return "it can\u{2019}t start with \u{201C}-\u{201D}" }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "it can\u{2019}t start or end with \u{201C}/\u{201D}" }
        if name.hasSuffix(".") { return "it can\u{2019}t end with a dot" }
        if name.contains("..") { return "it can\u{2019}t contain \u{201C}..\u{201D}" }
        if name.contains("//") { return "it can\u{2019}t contain \u{201C}//\u{201D}" }
        if name.contains("@{") { return "it can\u{2019}t contain \u{201C}@{\u{201D}" }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.hasPrefix(".") { return "a part can\u{2019}t start with a dot" }
            if component.hasSuffix(".lock") { return "a part can\u{2019}t end with \u{201C}.lock\u{201D}" }
        }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return "it can\u{2019}t contain control characters" }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) {
                return scalar == " " ? "it can\u{2019}t contain spaces" : "it can\u{2019}t contain \u{201C}\(Character(scalar))\u{201D}"
            }
        }
        return nil
    }
}

/// Creating, switching, renaming, deleting and tracking branches.
extension Repository {
    /// Throws `GitError.invalidBranchName` if the name is not allowed.
    func validateBranchName(_ name: String) async throws {
        if let reason = BranchName.problem(in: name) { throw GitError.invalidBranchName(name, reason: reason) }
        let result = try await git.run(["check-ref-format", "--branch", name], in: rootURL)
        guard result.succeeded else { throw GitError.invalidBranchName(name, reason: "git doesn\u{2019}t accept it") }
    }

    /// Creates a branch at `startPoint` (HEAD when nil), and switches to it when `checkout` is true.
    /// Starting from a remote-tracking branch makes the new branch track it.
    public func createBranch(_ name: String, from startPoint: String? = nil, checkout: Bool = true) async throws {
        try await validateBranchName(name)
        var arguments = checkout ? ["switch", "--create", name] : ["branch", name]
        if let startPoint { arguments.append(startPoint) }
        try await run(arguments)
    }

    /// Switches to a local branch. Uncommitted changes that don't conflict come along; if they would be
    /// overwritten git refuses and the error says so.
    public func switchBranch(to name: String) async throws {
        try await validateBranchName(name)
        try await run(["switch", name])
    }

    /// Switches to a remote-tracking branch such as `origin/feature`: to the local branch of the same name
    /// if there is one, otherwise by creating it with the remote branch as its upstream.
    public func switchToRemoteBranch(_ remoteBranch: String) async throws {
        guard let slash = remoteBranch.firstIndex(of: "/") else {
            throw GitError.invalidBranchName(remoteBranch, reason: "it isn\u{2019}t a remote branch")
        }
        let local = String(remoteBranch[remoteBranch.index(after: slash)...])
        try await validateBranchName(local)
        let exists = try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(local)"], in: rootURL).succeeded
        if exists {
            try await run(["switch", local])
        } else {
            try await run(["switch", "--create", local, "--track", remoteBranch])
        }
    }

    /// Checks out a commit, tag or remote branch without a branch (detached HEAD).
    public func switchDetached(to revision: String) async throws {
        try await run(["switch", "--detach", revision])
    }

    /// Renames a local branch, keeping its upstream configuration.
    public func renameBranch(_ old: String, to new: String) async throws {
        try await validateBranchName(new)
        try await run(["branch", "--move", old, new])
    }

    /// Deletes a local branch and returns the commit it pointed at, so the deletion can be undone.
    /// Without `force`, git refuses when the branch has commits that aren't merged anywhere else.
    @discardableResult
    public func deleteBranch(_ name: String, force: Bool = false) async throws -> String? {
        try await validateBranchName(name)
        let tip = try await resolve("refs/heads/\(name)")
        try await run(["branch", force ? "-D" : "-d", name])
        return tip
    }

    /// Makes `branch` track `upstream` (such as `origin/main`).
    public func setUpstream(of branch: String, to upstream: String) async throws {
        try await validateBranchName(branch)
        try await run(["branch", "--set-upstream-to=\(upstream)", branch])
    }

    public func unsetUpstream(of branch: String) async throws {
        try await validateBranchName(branch)
        try await run(["branch", "--unset-upstream", branch])
    }
}
