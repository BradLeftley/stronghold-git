import Foundation

/// One file a commit changed, from `--name-status`.
public struct CommitFileChange: Sendable, Equatable, Hashable, Identifiable {
    public enum Change: Sendable, Equatable, Hashable {
        case added
        case modified
        case deleted
        case renamed(similarity: Int)
        case copied(similarity: Int)
        case typeChanged
        case unmerged
        case unknown
    }

    public var change: Change
    /// The path after the commit.
    public var path: String
    /// For renames and copies, the path before.
    public var oldPath: String?

    public var id: String { path }

    public init(change: Change, path: String, oldPath: String? = nil) {
        self.change = change
        self.path = path
        self.oldPath = oldPath
    }

    /// The paths a diff limited to this file needs, so git can still pair a rename.
    public var pathspec: [String] {
        if let oldPath, oldPath != path { return [oldPath, path] }
        return [path]
    }
}

/// A commit in a file's history, with the file's name at that point (it may have been renamed since).
public struct FileHistoryEntry: Sendable, Equatable, Hashable, Identifiable {
    public var commit: Commit
    /// How the commit changed the file. Nil for merges, which git lists without a diff.
    public var change: CommitFileChange?
    /// The file's path in this commit.
    public var path: String

    public var id: String { commit.id }

    public init(commit: Commit, change: CommitFileChange?, path: String) {
        self.commit = commit
        self.change = change
        self.path = path
    }
}

/// Who last changed each line of a file, from `git blame --porcelain`.
public struct Blame: Sendable, Equatable {
    public var path: String
    public var lines: [BlameLine]
    /// The commits the lines point at, by ID.
    public var commits: [String: BlameCommit]

    public init(path: String, lines: [BlameLine], commits: [String: BlameCommit]) {
        self.path = path
        self.lines = lines
        self.commits = commits
    }

    public func commit(for line: BlameLine) -> BlameCommit? { commits[line.commitID] }

    /// Runs of consecutive lines from the same commit, for drawing one label per run.
    public var groups: [BlameGroup] {
        var groups: [BlameGroup] = []
        for (index, line) in lines.enumerated() {
            if let last = groups.last, last.commitID == line.commitID, last.range.upperBound == index {
                groups[groups.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                groups.append(BlameGroup(commitID: line.commitID, range: index..<(index + 1)))
            }
        }
        return groups
    }
}

/// Consecutive blame lines from one commit. `range` indexes `Blame.lines`.
public struct BlameGroup: Sendable, Equatable, Hashable {
    public var commitID: String
    public var range: Range<Int>
}

public struct BlameLine: Sendable, Equatable, Hashable {
    public var commitID: String
    /// The line's number in the commit that introduced it.
    public var originalLineNumber: Int
    /// The line's number in the blamed file.
    public var lineNumber: Int
    /// The file's path in the commit that introduced the line.
    public var originalPath: String
    public var text: String

    public init(commitID: String, originalLineNumber: Int, lineNumber: Int, originalPath: String, text: String) {
        self.commitID = commitID
        self.originalLineNumber = originalLineNumber
        self.lineNumber = lineNumber
        self.originalPath = originalPath
        self.text = text
    }
}

public struct BlameCommit: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var author: Signature
    public var committer: Signature
    public var summary: String
    /// The commit is the start of history (or the edge of the blamed range).
    public var isBoundary: Bool

    /// Lines that aren't committed yet have the all-zero ID.
    public var isUncommitted: Bool { id.allSatisfy { $0 == "0" } }
    public var shortID: String { String(id.prefix(7)) }

    public init(id: String, author: Signature, committer: Signature, summary: String, isBoundary: Bool = false) {
        self.id = id
        self.author = author
        self.committer = committer
        self.summary = summary
        self.isBoundary = isBoundary
    }
}
