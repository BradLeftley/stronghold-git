import Foundation

/// One line inside a hunk.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`, which applies to the line before it.
        case noNewlineAtEnd
    }

    public var kind: Kind
    /// The line's text without the leading `+`, `-` or space.
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(kind: Kind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A `@@ -a,b +c,d @@` block.
public struct DiffHunk: Sendable, Equatable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text after the second `@@`, usually the enclosing function.
    public var section: String
    public var lines: [DiffLine]

    /// The header line exactly as git writes it, needed to build patches for line staging.
    public var header: String {
        "@@ -\(Self.range(oldStart, oldCount)) +\(Self.range(newStart, newCount)) @@" + (section.isEmpty ? "" : " " + section)
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "",
                lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

/// The changes to one file.
public struct FileDiff: Sendable, Equatable, Hashable, Identifiable {
    public enum Change: Sendable, Equatable, Hashable {
        case added
        case deleted
        case modified
        case renamed(similarity: Int)
        case copied(similarity: Int)
    }

    /// Nil for an added file.
    public var oldPath: String?
    /// Nil for a deleted file.
    public var newPath: String?
    public var change: Change
    public var oldMode: String?
    public var newMode: String?
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public var id: String { (newPath ?? oldPath) ?? "" }
    /// The path to show in lists.
    public var path: String { (newPath ?? oldPath) ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }

    public init(oldPath: String?, newPath: String?, change: Change, oldMode: String? = nil, newMode: String? = nil,
                isBinary: Bool = false, hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.oldMode = oldMode
        self.newMode = newMode
        self.isBinary = isBinary
        self.hunks = hunks
    }
}

/// What `Repository.diff` compares.
public enum DiffTarget: Sendable, Equatable {
    /// Work tree against the index (unstaged changes).
    case workTree
    /// Index against HEAD (staged changes).
    case staged
    /// A commit against its first parent.
    case commit(String)
    /// Two revisions.
    case range(from: String, to: String)
}
