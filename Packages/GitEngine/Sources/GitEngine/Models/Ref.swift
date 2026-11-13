import Foundation

/// A branch, remote-tracking branch or tag.
public struct Ref: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        case localBranch
        case remoteBranch(remote: String)
        case tag
        case other
    }

    /// The full name, such as `refs/heads/main`.
    public var name: String
    public var kind: Kind
    /// The object the ref points at.
    public var target: String
    /// For annotated tags, the commit the tag points at.
    public var peeledTarget: String?
    /// For local branches, the full name of the upstream, such as `refs/remotes/origin/main`.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// The upstream is configured but no longer exists on the remote.
    public var upstreamGone: Bool
    /// The checked-out branch.
    public var isHead: Bool
    /// For symbolic refs such as `refs/remotes/origin/HEAD`, what they point at.
    public var symbolicTarget: String?

    public var id: String { name }

    /// The name as people write it: `main`, `origin/main`, `v1.0`.
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// The commit this ref resolves to (peeled for annotated tags).
    public var commitID: String { peeledTarget ?? target }

    public init(name: String, kind: Kind, target: String, peeledTarget: String? = nil, upstream: String? = nil,
                ahead: Int = 0, behind: Int = 0, upstreamGone: Bool = false, isHead: Bool = false,
                symbolicTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.target = target
        self.peeledTarget = peeledTarget
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
        self.symbolicTarget = symbolicTarget
    }
}

/// A configured remote.
public struct Remote: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var fetchURL: String?
    /// Explicit push URLs; when empty, git pushes to the fetch URL.
    public var pushURLs: [String]

    public var id: String { name }
    public var effectivePushURL: String? { pushURLs.first ?? fetchURL }

    public init(name: String, fetchURL: String? = nil, pushURLs: [String] = []) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURLs = pushURLs
    }
}
