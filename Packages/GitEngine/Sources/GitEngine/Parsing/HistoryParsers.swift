import Foundation

/// Parses `--name-status -z` output: a status token, then one path (two for renames and copies).
public enum NameStatusParser {
    public static func parse(_ data: Data) throws -> [CommitFileChange] {
        let fields = data.nulSeparatedFields()
        var index = 0
        var changes: [CommitFileChange] = []
        while index < fields.count {
            guard let change = try read(fields, at: &index) else {
                throw GitError.unexpectedOutput("name-status token \(fields[index].prefix(20))")
            }
            changes.append(change)
        }
        return changes
    }

    /// Reads one entry starting at `index`, or returns nil (leaving `index` alone) if the field there
    /// isn't a status token. Git puts a newline before the first token when it follows a log record.
    static func read(_ fields: [String], at index: inout Int) throws -> CommitFileChange? {
        guard index < fields.count else { return nil }
        let token = fields[index].drop { $0 == "\n" }
        guard let letter = token.first, isStatusToken(token) else { return nil }
        let score = Int(token.dropFirst()) ?? 0
        let change: CommitFileChange.Change = switch letter {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "R": .renamed(similarity: score)
        case "C": .copied(similarity: score)
        case "T": .typeChanged
        case "U": .unmerged
        default: .unknown
        }
        let pathCount = (letter == "R" || letter == "C") ? 2 : 1
        guard index + pathCount < fields.count else {
            throw GitError.unexpectedOutput("name-status entry missing its path")
        }
        defer { index += 1 + pathCount }
        if pathCount == 2 {
            return CommitFileChange(change: change, path: fields[index + 2], oldPath: fields[index + 1])
        }
        return CommitFileChange(change: change, path: fields[index + 1])
    }

    /// `M`, `A`, `R100` and so on.
    static func isStatusToken(_ token: Substring) -> Bool {
        guard let letter = token.first, "ACDMRTUXB".contains(letter), token.count <= 4 else { return false }
        return token.dropFirst().allSatisfy(\.isASCII) && token.dropFirst().allSatisfy(\.isNumber)
    }
}

/// Parses `git log --follow -z --name-status` with the `LogParser` format: each commit record is
/// followed by its name-status entries (none for merges).
public enum FileHistoryParser {
    public static func parse(_ data: Data, path: String) throws -> [FileHistoryEntry] {
        let fields = data.nulSeparatedFields()
        var index = 0
        var entries: [FileHistoryEntry] = []
        // Walking newest to oldest, a rename moves the file back to its old name.
        var currentPath = path
        while index < fields.count {
            guard index + LogParser.width <= fields.count else {
                throw GitError.unexpectedOutput("file history record cut short")
            }
            let commit = try LogParser.commit(from: fields[index..<index + LogParser.width])
            index += LogParser.width
            var changes: [CommitFileChange] = []
            while let change = try NameStatusParser.read(fields, at: &index) { changes.append(change) }
            let change = changes.first { $0.path == currentPath } ?? changes.first
            let pathHere = change?.path ?? currentPath
            entries.append(FileHistoryEntry(commit: commit, change: change, path: pathHere))
            if let old = change?.oldPath, case .renamed = change?.change { currentPath = old } else { currentPath = pathHere }
        }
        return entries
    }
}

/// Parses `git blame --porcelain`.
public enum BlameParser {
    public static func parse(_ data: Data, path: String) throws -> Blame {
        var lines: [BlameLine] = []
        var commits: [String: BlameCommit] = [:]
        var partial: [String: [String: String]] = [:]
        var boundaries: Set<String> = []
        var filenames: [String: String] = [:]
        var current: (id: String, original: Int, final: Int)?

        for rawLine in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if rawLine.first == UInt8(ascii: "\t") {
                guard let header = current else { throw GitError.unexpectedOutput("blame line without a header") }
                let text = String(decoding: rawLine.dropFirst(), as: UTF8.self)
                lines.append(BlameLine(commitID: header.id, originalLineNumber: header.original, lineNumber: header.final,
                                       originalPath: filenames[header.id] ?? path, text: text))
                current = nil
                continue
            }
            let line = String(decoding: rawLine, as: UTF8.self)
            if line.isEmpty { continue }
            if current == nil {
                // "<sha> <original line> <final line> [<lines in group>]"
                let parts = line.split(separator: " ")
                guard parts.count >= 3, parts[0].count >= 40, parts[0].allSatisfy(\.isHexDigit),
                      let original = Int(parts[1]), let final = Int(parts[2]) else {
                    throw GitError.unexpectedOutput("blame header \(line.prefix(60))")
                }
                current = (String(parts[0]), original, final)
                continue
            }
            guard let id = current?.id else { continue }
            let key: Substring, value: Substring
            if let space = line.firstIndex(of: " ") {
                key = line[..<space]
                value = line[line.index(after: space)...]
            } else {
                key = line[...]
                value = ""
            }
            switch key {
            case "boundary": boundaries.insert(id)
            case "filename": filenames[id] = String(value)
            default: partial[id, default: [:]][String(key)] = String(value)
            }
        }

        for (id, fields) in partial {
            func signature(_ role: String) -> Signature {
                var email = fields["\(role)-mail"] ?? ""
                if email.hasPrefix("<") && email.hasSuffix(">") { email = String(email.dropFirst().dropLast()) }
                let time = TimeInterval(fields["\(role)-time"] ?? "") ?? 0
                return Signature(name: fields[role] ?? "", email: email, date: Date(timeIntervalSince1970: time))
            }
            commits[id] = BlameCommit(id: id, author: signature("author"), committer: signature("committer"),
                                      summary: fields["summary"] ?? "", isBoundary: boundaries.contains(id))
        }
        return Blame(path: path, lines: lines, commits: commits)
    }
}
