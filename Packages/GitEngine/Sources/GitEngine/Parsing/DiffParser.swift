import Foundation

/// Parses unified diffs from `git diff` / `git show` with the `a/` and `b/` prefixes forced on.
public enum DiffParser {
    public static func parse(_ data: Data) throws -> [FileDiff] {
        try parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) throws -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var oldRemaining = 0, newRemaining = 0
        var oldLine = 0, newLine = 0

        func finishHunk() {
            if let finished = hunk { current?.hunks.append(finished) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let finished = current { files.append(finished) }
            current = nil
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            // Inside a hunk, lines are content until the counts run out.
            if hunk != nil, oldRemaining > 0 || newRemaining > 0 || line.hasPrefix("\\") {
                guard let marker = line.first else {
                    // Some tools strip the space from empty context lines.
                    hunk?.lines.append(DiffLine(kind: .context, text: "", oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                    continue
                }
                let content = String(line.dropFirst())
                switch marker {
                case " ":
                    hunk?.lines.append(DiffLine(kind: .context, text: content, oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                case "-":
                    hunk?.lines.append(DiffLine(kind: .deletion, text: content, oldLineNumber: oldLine))
                    oldLine += 1; oldRemaining -= 1
                case "+":
                    hunk?.lines.append(DiffLine(kind: .addition, text: content, newLineNumber: newLine))
                    newLine += 1; newRemaining -= 1
                case "\\":
                    hunk?.lines.append(DiffLine(kind: .noNewlineAtEnd, text: content))
                default:
                    throw GitError.unexpectedOutput("diff line \"\(line.prefix(120))\"")
                }
                continue
            }

            if line.hasPrefix("diff --git ") {
                finishFile()
                let paths = splitGitHeader(line.dropFirst("diff --git ".count))
                current = FileDiff(oldPath: paths?.old, newPath: paths?.new, change: .modified)
            } else if line.hasPrefix("@@") {
                guard current != nil, let parsed = parseHunkHeader(line) else {
                    throw GitError.unexpectedOutput("hunk header \"\(line.prefix(120))\"")
                }
                finishHunk()
                hunk = parsed
                oldRemaining = parsed.oldCount; newRemaining = parsed.newCount
                oldLine = parsed.oldStart; newLine = parsed.newStart
            } else if current != nil {
                parseExtendedHeader(line, into: &current!)
            }
        }
        finishFile()
        return files
    }

    private static func parseExtendedHeader(_ line: String, into file: inout FileDiff) {
        func value(after prefix: String) -> String? {
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        if let mode = value(after: "new file mode ") {
            file.change = .added; file.newMode = mode; file.oldPath = nil
        } else if let mode = value(after: "deleted file mode ") {
            file.change = .deleted; file.oldMode = mode; file.newPath = nil
        } else if let mode = value(after: "old mode ") {
            file.oldMode = mode
        } else if let mode = value(after: "new mode ") {
            file.newMode = mode
        } else if let score = value(after: "similarity index ") {
            let similarity = Int(score.dropLast()) ?? 0
            if case .copied = file.change { file.change = .copied(similarity: similarity) }
            else { file.change = .renamed(similarity: similarity) }
        } else if let path = value(after: "rename from ") {
            file.oldPath = GitPathUnquoter.unquote(path[...])
            if case .renamed = file.change {} else { file.change = .renamed(similarity: 0) }
        } else if let path = value(after: "rename to ") {
            file.newPath = GitPathUnquoter.unquote(path[...])
        } else if let path = value(after: "copy from ") {
            file.oldPath = GitPathUnquoter.unquote(path[...])
            file.change = .copied(similarity: { if case .renamed(let s) = file.change { return s }; return 0 }())
        } else if let path = value(after: "copy to ") {
            file.newPath = GitPathUnquoter.unquote(path[...])
        } else if line.hasPrefix("index ") {
            // "index abc..def 100644": the trailing mode applies to both sides.
            let parts = line.split(separator: " ")
            if parts.count == 3 { file.oldMode = file.oldMode ?? String(parts[2]); file.newMode = file.newMode ?? String(parts[2]) }
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            file.isBinary = true
        } else if let path = value(after: "--- ") {
            if path != "/dev/null", file.oldPath == nil, file.change != .added { file.oldPath = stripPrefix(path, "a/") }
        } else if let path = value(after: "+++ ") {
            if path != "/dev/null", file.newPath == nil, file.change != .deleted { file.newPath = stripPrefix(path, "b/") }
        }
    }

    private static func stripPrefix(_ raw: String, _ prefix: String) -> String {
        let unquoted = GitPathUnquoter.unquote(raw.hasSuffix("\t") ? raw.dropLast()[...] : raw[...])
        return unquoted.hasPrefix(prefix) ? String(unquoted.dropFirst(prefix.count)) : unquoted
    }

    /// Splits `a/<old> b/<new>`. Unquoted paths may contain spaces, so when both sides are unquoted we
    /// rely on the two paths being equal (true unless it's a rename or copy, whose headers give the paths).
    static func splitGitHeader(_ header: Substring) -> (old: String, new: String)? {
        if header.hasPrefix("\"") {
            // Quoted old path: find its closing quote.
            var escaped = false
            var end: Substring.Index?
            for index in header.indices.dropFirst() {
                let character = header[index]
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { end = index; break }
            }
            guard let end else { return nil }
            let old = GitPathUnquoter.unquote(header[...end])
            let rest = header[header.index(after: end)...].drop { $0 == " " }
            return (stripSide(old, "a/"), stripSide(GitPathUnquoter.unquote(rest), "b/"))
        }
        if header.hasSuffix("\""), let quoteStart = header.range(of: " \"b/", options: .backwards) {
            let old = String(header[..<quoteStart.lowerBound])
            let new = GitPathUnquoter.unquote(header[header.index(after: quoteStart.lowerBound)...])
            return (stripSide(old, "a/"), stripSide(new, "b/"))
        }
        // Same path on both sides: "a/P b/P", so the length is 2 * len(P) + 5.
        let characters = Array(header)
        if (characters.count - 5) % 2 == 0, characters.count > 5 {
            let length = (characters.count - 5) / 2
            let old = String(characters[2..<(2 + length)])
            let new = String(characters[(5 + length)...])
            if old == new, header.hasPrefix("a/") { return (old, new) }
        }
        if let separator = header.range(of: " b/") {
            return (stripSide(String(header[..<separator.lowerBound]), "a/"),
                    String(header[separator.upperBound...]))
        }
        return nil
    }

    private static func stripSide(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@ section`.
    static func parseHunkHeader(_ line: String) -> DiffHunk? {
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@ -") != nil, let oldStart = scanner.scanInt() else { return nil }
        let oldCount = scanner.scanString(",") != nil ? scanner.scanInt() : 1
        guard let oldCount, scanner.scanString(" +") != nil, let newStart = scanner.scanInt() else { return nil }
        let newCount = scanner.scanString(",") != nil ? scanner.scanInt() : 1
        guard let newCount, scanner.scanString(" @@") != nil else { return nil }
        let rest = line[scanner.currentIndex...]
        let section = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        return DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: section)
    }
}
