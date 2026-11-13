import Foundation
import GitEngine

/// How a changed file is labelled in lists.
public enum ChangeBadge: String, Sendable, Equatable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case conflicted = "!"
    case ignored = "I"

    public var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .ignored: "Ignored"
        }
    }
}

public extension StatusEntry {
    /// The badge for the staged side of this entry, if it has staged changes.
    var stagedBadge: ChangeBadge? {
        guard hasStagedChanges else { return nil }
        return Self.badge(for: index, kind: kind)
    }

    /// The badge for the unstaged side, if it has unstaged changes.
    var unstagedBadge: ChangeBadge? {
        if case .untracked = kind { return .untracked }
        guard hasUnstagedChanges else { return nil }
        return Self.badge(for: workTree, kind: .ordinary)
    }

    /// One badge summarising the entry.
    var badge: ChangeBadge {
        switch kind {
        case .unmerged: return .conflicted
        case .untracked: return .untracked
        case .ignored: return .ignored
        default: return stagedBadge ?? unstagedBadge ?? .modified
        }
    }

    private static func badge(for change: FileChange, kind: Kind) -> ChangeBadge {
        switch change {
        case .added: return .added
        case .deleted: return .deleted
        case .renamed: return .renamed
        case .copied: return .copied
        case .typeChanged: return .typeChanged
        case .unmerged: return .conflicted
        case .modified, .unmodified:
            if case .renamed = kind { return .renamed }
            if case .copied = kind { return .copied }
            return .modified
        }
    }
}

public extension CommitFileChange {
    /// The badge for this file in a commit's file list.
    var badge: ChangeBadge {
        switch change {
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .copied: .copied
        case .typeChanged: .typeChanged
        case .unmerged: .conflicted
        case .modified, .unknown: .modified
        }
    }
}

public extension Date {
    /// "3 hours ago" for recent dates, otherwise the short date, for compact lists like blame.
    func compactDescription(relativeTo now: Date = Date()) -> String {
        let age = now.timeIntervalSince(self)
        if age >= 0 && age < 7 * 24 * 3600 {
            return formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
}
