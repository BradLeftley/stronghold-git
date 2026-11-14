import Foundation

/// Why a fetch, pull or push failed, worked out from what git printed.
public enum RemoteFailure: Sendable, Equatable {
    /// The server refused the credentials, or none were available.
    case authenticationFailed
    /// The server doesn't know the repository, or the account can't see it.
    case repositoryNotFound
    /// The network or host couldn't be reached.
    case hostUnreachable
    /// SSH didn't trust the host, or the key was refused.
    case sshFailed
    /// The remote has commits this branch doesn't have.
    case pushRejectedNonFastForward
    /// A hook or branch protection on the server refused the push.
    case pushDeclined
    /// A force push would overwrite someone else's work (the remote moved since the last fetch).
    case staleInfo
    /// The branch has no upstream to pull from.
    case noUpstream
    /// The repository has no remote configured.
    case noRemote
    /// Pulling stopped with merge conflicts.
    case mergeConflict
    /// The branches diverged and a fast-forward-only pull can't join them.
    case cannotFastForward
    /// Local changes would be overwritten by the merge or checkout.
    case localChangesInTheWay
    /// Something else; the message is git's own.
    case other

    /// Matches git's (C-locale) messages.
    public static func classify(_ output: String) -> RemoteFailure {
        let text = output.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("host key verification failed", "permission denied (publickey", "no matching host key",
               "remote host identification has changed") { return .sshFailed }
        if has("authentication failed", "could not read username", "could not read password",
               "invalid username or password", "http basic: access denied", "terminal prompts disabled",
               "requested url returned error: 401", "requested url returned error: 403",
               "support for password authentication was removed") { return .authenticationFailed }
        if has("repository not found", "does not appear to be a git repository", "requested url returned error: 404",
               "could not read from remote repository") && !has("could not resolve host") {
            return .repositoryNotFound
        }
        if has("could not resolve host", "unable to access", "connection timed out", "connection refused",
               "network is unreachable", "operation timed out", "failed to connect", "temporary failure in name resolution",
               "connection reset", "early eof") { return .hostUnreachable }
        if has("stale info") { return .staleInfo }
        if has("non-fast-forward", "fetch first", "[rejected]", "failed to push some refs") && !has("pre-receive hook declined",
               "protected branch", "remote rejected") {
            return .pushRejectedNonFastForward
        }
        if has("remote rejected", "pre-receive hook declined", "protected branch", "hook declined") { return .pushDeclined }
        if has("no tracking information", "has no upstream branch", "no upstream configured",
               "no such ref was fetched") { return .noUpstream }
        if has("no configured push destination", "no remote repository specified", "no remotes") { return .noRemote }
        if has("not possible to fast-forward", "diverging branches can't be fast-forwarded") { return .cannotFastForward }
        if has("conflict (", "automatic merge failed", "could not apply", "fix conflicts") { return .mergeConflict }
        if has("would be overwritten by merge", "would be overwritten by checkout",
               "your local changes to the following files would be overwritten",
               "please commit your changes or stash them", "cannot pull with rebase: you have unstaged changes",
               "cannot pull with rebase: your index contains uncommitted changes") { return .localChangesInTheWay }
        return .other
    }

    /// A sentence for the person using the app, with what to do next.
    public var advice: String? {
        switch self {
        case .authenticationFailed:
            return "The server didn't accept your credentials. Check the account for this repository in Settings and try again."
        case .repositoryNotFound:
            return "The repository wasn't found, or your account can't access it. Check the remote address and your account."
        case .hostUnreachable:
            return "Couldn't reach the server. Check your internet connection and the remote address."
        case .sshFailed:
            return "SSH couldn't connect. Make sure your key is loaded in ssh-agent and the host is in known_hosts."
        case .pushRejectedNonFastForward:
            return "The remote has commits you don't have. Pull first, then push again."
        case .pushDeclined:
            return "The server declined the push. The branch may be protected, or a server hook refused it."
        case .staleInfo:
            return "The remote branch changed since your last fetch, so the force push was stopped. Fetch, check the changes, then try again."
        case .noUpstream:
            return "This branch isn't tracking a remote branch. Push it once to publish it and set the upstream."
        case .noRemote:
            return "This repository has no remote. Add one before fetching, pulling or pushing."
        case .mergeConflict:
            return "The pull stopped because of conflicts. Resolve them, then commit to finish."
        case .cannotFastForward:
            return "Your branch and the remote have both moved, so it can't be fast-forwarded. Pull with merge or rebase instead."
        case .localChangesInTheWay:
            return "Local changes would be overwritten. Commit or stash them, then try again."
        case .other:
            return nil
        }
    }
}

/// Hides credentials embedded in URLs (`https://user:token@host/…`) before text is shown or logged.
public enum Redactor {
    public static func redact(_ text: String) -> String {
        guard text.contains("@") else { return text }
        var result = ""
        var rest = Substring(text)
        while let scheme = rest.range(of: "://") {
            result += rest[..<scheme.upperBound]
            rest = rest[scheme.upperBound...]
            // The authority ends at the first /, whitespace or quote.
            let end = rest.firstIndex(where: { $0 == "/" || $0.isWhitespace || $0 == "'" || $0 == "\"" }) ?? rest.endIndex
            let authority = rest[..<end]
            if let at = authority.lastIndex(of: "@") {
                result += "***" + authority[at...]
            } else {
                result += authority
            }
            rest = rest[end...]
        }
        return result + rest
    }
}
