import Foundation

/// Parses `git status --porcelain=v2 --branch --show-stash -z`.
public enum StatusParser {
    public static func parse(_ data: Data) throws -> RepositoryStatus {
        var status = RepositoryStatus()
        var fields = data.nulSeparatedFields()[...]

        while let field = fields.popFirst() {
            guard let tag = field.first else { continue }
            switch tag {
            case "#":
                parseHeader(field, into: &status)
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { throw malformed(field) }
                let (index, workTree) = try changes(parts[1], field: field)
                status.entries.append(StatusEntry(kind: .ordinary, path: String(parts[8]), index: index,
                                                  workTree: workTree, submodule: submodule(parts[2])))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, let original = fields.popFirst() else { throw malformed(field) }
                let (index, workTree) = try changes(parts[1], field: field)
                let score = parts[8]
                let similarity = Int(score.dropFirst()) ?? 0
                let kind: StatusEntry.Kind = score.first == "C" ? .copied(similarity: similarity)
                                                                : .renamed(similarity: similarity)
                status.entries.append(StatusEntry(kind: kind, path: String(parts[9]), originalPath: original,
                                                  index: index, workTree: workTree, submodule: submodule(parts[2])))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { throw malformed(field) }
                let (index, workTree) = try changes(parts[1], field: field)
                guard let conflict = ConflictKind(rawValue: String(parts[1])) else { throw malformed(field) }
                status.entries.append(StatusEntry(kind: .unmerged(conflict), path: String(parts[10]), index: index,
                                                  workTree: workTree, submodule: submodule(parts[2])))
            case "?", "!":
                guard field.count > 2 else { throw malformed(field) }
                status.entries.append(StatusEntry(kind: tag == "?" ? .untracked : .ignored,
                                                  path: String(field.dropFirst(2))))
            default:
                throw malformed(field)
            }
        }
        return status
    }

    private static func parseHeader(_ field: String, into status: inout RepositoryStatus) {
        let parts = field.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.branch.headOID = value == "(initial)" ? nil : value
        case "branch.head": status.branch.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.branch.upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                status.branch.ahead = Int(counts[0].dropFirst())
                status.branch.behind = Int(counts[1].dropFirst())
            }
        case "stash": status.stashCount = Int(value) ?? 0
        default: break // Unknown headers are allowed by the format.
        }
    }

    private static func changes(_ xy: Substring, field: String) throws -> (FileChange, FileChange) {
        guard xy.count == 2, let x = FileChange(rawValue: xy.first!), let y = FileChange(rawValue: xy.last!) else {
            throw malformed(field)
        }
        return (x, y)
    }

    private static func submodule(_ token: Substring) -> SubmoduleState? {
        guard token.first == "S", token.count == 4 else { return nil }
        let flags = Array(token)
        return SubmoduleState(commitChanged: flags[1] == "C", hasTrackedChanges: flags[2] == "M",
                              hasUntrackedChanges: flags[3] == "U")
    }

    private static func malformed(_ field: String) -> GitError {
        .unexpectedOutput("status line \"\(field.prefix(120))\"")
    }
}
