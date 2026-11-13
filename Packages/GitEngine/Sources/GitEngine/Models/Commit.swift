import Foundation

/// A person and time attached to a commit.
public struct Signature: Sendable, Equatable, Hashable {
    public var name: String
    public var email: String
    public var date: Date

    public init(name: String, email: String, date: Date) {
        self.name = name
        self.email = email
        self.date = date
    }
}

/// A commit read from `git log`.
public struct Commit: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var parents: [String]
    public var author: Signature
    public var committer: Signature
    /// The full message, without the trailing newline.
    public var message: String
    /// Refs pointing at this commit, in git's order.
    public var decorations: [Decoration]

    /// The first line of the message.
    public var summary: String {
        String(message.prefix { $0 != "\n" })
    }

    /// The message after the summary and the blank line that follows it.
    public var body: String {
        guard let newline = message.firstIndex(of: "\n") else { return "" }
        return message[message.index(after: newline)...].trimmingCharacters(in: .newlines)
    }

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(id: String, parents: [String], author: Signature, committer: Signature, message: String,
                decorations: [Decoration] = []) {
        self.id = id
        self.parents = parents
        self.author = author
        self.committer = committer
        self.message = message
        self.decorations = decorations
    }
}

/// A ref pointing at a commit, read from `%D` with `--decorate=full` so a local branch with a slash in
/// its name (`feature/x`) can be told apart from a remote-tracking branch (`origin/x`).
public struct Decoration: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// A detached HEAD.
        case detachedHead
        case localBranch
        case remoteBranch
        case tag
        case other
    }

    public var kind: Kind
    /// The full ref name, such as `refs/heads/main`, or `HEAD` for a detached HEAD.
    public var fullName: String
    /// HEAD points here: the checked-out branch, or a detached HEAD.
    public var isHead: Bool

    public init(kind: Kind, fullName: String, isHead: Bool = false) {
        self.kind = kind
        self.fullName = fullName
        self.isHead = isHead
    }

    /// Parses one entry of `%D` written with `--decorate=full`: `HEAD -> refs/heads/main`, `HEAD`,
    /// `tag: refs/tags/v1`, `refs/remotes/origin/main` or `refs/heads/feature/x`.
    public init(parsing text: String) {
        var name = text
        var isHead = false
        if name == "HEAD" {
            self.init(kind: .detachedHead, fullName: "HEAD", isHead: true)
            return
        }
        if name.hasPrefix("HEAD -> ") {
            name.removeFirst("HEAD -> ".count)
            isHead = true
        }
        if name.hasPrefix("tag: ") { name.removeFirst("tag: ".count) }
        let kind: Kind = if name.hasPrefix("refs/heads/") {
            .localBranch
        } else if name.hasPrefix("refs/remotes/") {
            .remoteBranch
        } else if name.hasPrefix("refs/tags/") {
            .tag
        } else {
            .other
        }
        self.init(kind: kind, fullName: name, isHead: isHead)
    }

    /// The name as people write it: `main`, `feature/x`, `origin/main`, `v1.0`.
    public var name: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }
}

/// What to read with `Repository.log`.
public struct LogQuery: Sendable, Equatable {
    /// Revisions to start from. Empty means HEAD.
    public var revisions: [String]
    /// Walk every branch, remote-tracking branch and tag, plus HEAD, ignoring `revisions`. Stashes are
    /// left out: they're shown on their own.
    public var allRefs: Bool
    public var limit: Int?
    public var skip: Int
    /// Only commits touching these paths. Pathspec magic such as `:(glob)` is allowed.
    public var paths: [String]
    /// Parents before children with branches kept together, which the history graph needs.
    public var topologicalOrder: Bool
    /// Only commits whose message contains this text (`--grep`).
    public var messagePattern: String?
    /// Only commits whose author name or email contains this text (`--author`).
    public var authorPattern: String?
    /// Only commits that add or remove this text (`-S`, the "pickaxe").
    public var contentPattern: String?
    /// Match `messagePattern` and `authorPattern` as plain text rather than regular expressions.
    public var fixedStrings: Bool
    /// Ignore case in `messagePattern` and `authorPattern`.
    public var ignoreCase: Bool

    public init(revisions: [String] = [], allRefs: Bool = false, limit: Int? = nil, skip: Int = 0,
                paths: [String] = [], topologicalOrder: Bool = false, messagePattern: String? = nil,
                authorPattern: String? = nil, contentPattern: String? = nil, fixedStrings: Bool = true,
                ignoreCase: Bool = true) {
        self.revisions = revisions
        self.allRefs = allRefs
        self.limit = limit
        self.skip = skip
        self.paths = paths
        self.topologicalOrder = topologicalOrder
        self.messagePattern = messagePattern
        self.authorPattern = authorPattern
        self.contentPattern = contentPattern
        self.fixedStrings = fixedStrings
        self.ignoreCase = ignoreCase
    }

    /// Pathspecs matching any file whose name, or the name of a folder it's in, contains `text`,
    /// ignoring case. Used to search history by file name.
    public static func pathsContaining(_ text: String) -> [String] {
        var escaped = ""
        for character in text {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return [":(glob,icase)**/*\(escaped)*", ":(glob,icase)**/*\(escaped)*/**"]
    }

    /// The options this query adds to `git log`, before `--end-of-options`.
    var filterArguments: [String] {
        var arguments: [String] = []
        if let messagePattern, !messagePattern.isEmpty { arguments.append("--grep=\(messagePattern)") }
        if let authorPattern, !authorPattern.isEmpty { arguments.append("--author=\(authorPattern)") }
        if let contentPattern, !contentPattern.isEmpty { arguments.append("-S\(contentPattern)") }
        let filtersText = (messagePattern?.isEmpty == false) || (authorPattern?.isEmpty == false)
        if filtersText && fixedStrings { arguments.append("--fixed-strings") }
        if filtersText && ignoreCase { arguments.append("--regexp-ignore-case") }
        return arguments
    }
}
