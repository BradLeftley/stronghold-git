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
    /// Ref names pointing at this commit, as git decorates them (`HEAD -> main`, `origin/main`, `tag: v1.0`).
    public var decorations: [String]

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
                decorations: [String] = []) {
        self.id = id
        self.parents = parents
        self.author = author
        self.committer = committer
        self.message = message
        self.decorations = decorations
    }
}

/// What to read with `Repository.log`.
public struct LogQuery: Sendable, Equatable {
    /// Revisions to start from. Empty means HEAD.
    public var revisions: [String]
    /// Walk every ref (`--all`), ignoring `revisions`.
    public var allRefs: Bool
    public var limit: Int?
    public var skip: Int
    /// Only commits touching these paths.
    public var paths: [String]
    /// Parents before children with branches kept together, which the history graph needs.
    public var topologicalOrder: Bool

    public init(revisions: [String] = [], allRefs: Bool = false, limit: Int? = nil, skip: Int = 0,
                paths: [String] = [], topologicalOrder: Bool = false) {
        self.revisions = revisions
        self.allRefs = allRefs
        self.limit = limit
        self.skip = skip
        self.paths = paths
        self.topologicalOrder = topologicalOrder
    }
}
