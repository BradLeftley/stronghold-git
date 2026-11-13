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
