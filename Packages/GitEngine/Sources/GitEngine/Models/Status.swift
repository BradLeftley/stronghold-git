import Foundation

/// The state of one side (index or work tree) of a changed path, from porcelain v2's `XY` field.
public enum FileChange: Character, Sendable, Equatable {
    case unmodified = "."
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
}

/// Submodule state from porcelain v2's `<sub>` field (`N...` for a normal path, `S<c><m><u>` for a submodule).
public struct SubmoduleState: Sendable, Equatable {
    public var commitChanged: Bool
    public var hasTrackedChanges: Bool
    public var hasUntrackedChanges: Bool
}

/// Which side created a conflict, from the `XY` code of an unmerged entry.
public enum ConflictKind: String, Sendable, Equatable {
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case deletedByThem = "UD"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case bothAdded = "AA"
    case bothModified = "UU"
}

/// One line of `git status --porcelain=v2`.
public struct StatusEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case ordinary
        case renamed(similarity: Int)
        case copied(similarity: Int)
        case unmerged(ConflictKind)
        case untracked
        case ignored
    }

    public var kind: Kind
    /// Path relative to the repository root.
    public var path: String
    /// For renames and copies, the path it came from.
    public var originalPath: String?
    public var index: FileChange
    public var workTree: FileChange
    /// Nil for paths that aren't submodules.
    public var submodule: SubmoduleState?

    public var id: String { path }

    /// True if the index holds a change to commit.
    public var hasStagedChanges: Bool {
        switch kind {
        case .ordinary, .renamed, .copied: return index != .unmodified
        case .unmerged, .untracked, .ignored: return false
        }
    }

    /// True if the work tree differs from the index (including untracked files).
    public var hasUnstagedChanges: Bool {
        switch kind {
        case .ordinary, .renamed, .copied: return workTree != .unmodified
        case .untracked: return true
        case .unmerged, .ignored: return false
        }
    }

    public var isConflicted: Bool {
        if case .unmerged = kind { return true }
        return false
    }

    public init(kind: Kind, path: String, originalPath: String? = nil, index: FileChange = .unmodified,
                workTree: FileChange = .unmodified, submodule: SubmoduleState? = nil) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.workTree = workTree
        self.submodule = submodule
    }
}

/// The `# branch.*` headers of porcelain v2.
public struct BranchStatus: Sendable, Equatable {
    /// The commit HEAD points at; nil before the first commit.
    public var headOID: String?
    /// The checked-out branch; nil when HEAD is detached.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?

    public var isDetached: Bool { branch == nil }
    public var isUnborn: Bool { headOID == nil }

    public init(headOID: String? = nil, branch: String? = nil, upstream: String? = nil,
                ahead: Int? = nil, behind: Int? = nil) {
        self.headOID = headOID
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// The parsed result of `git status`.
public struct RepositoryStatus: Sendable, Equatable {
    public var branch: BranchStatus
    public var entries: [StatusEntry]
    /// Number of stash entries, when requested.
    public var stashCount: Int

    public var staged: [StatusEntry] { entries.filter(\.hasStagedChanges) }
    public var unstaged: [StatusEntry] { entries.filter(\.hasUnstagedChanges) }
    public var conflicted: [StatusEntry] { entries.filter(\.isConflicted) }
    /// True if nothing is staged, modified, conflicted or untracked.
    public var isClean: Bool { entries.allSatisfy { $0.kind == .ignored } }

    public init(branch: BranchStatus = BranchStatus(), entries: [StatusEntry] = [], stashCount: Int = 0) {
        self.branch = branch
        self.entries = entries
        self.stashCount = stashCount
    }
}
