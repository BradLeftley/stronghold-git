import Foundation

/// Identifies one line of a `FileDiff`: the hunk's position in `hunks` and the line's position in `lines`.
public struct LineSelection: Sendable, Hashable {
    public var hunk: Int
    public var line: Int

    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }
}

/// What a patch built from part of a diff is for.
public enum PatchIntent: Sendable, Equatable {
    /// Add the selected changes of an unstaged diff to the index (`git apply --cached`).
    case stage
    /// Take the selected changes of a staged diff out of the index (`git apply --cached --reverse`).
    case unstage
    /// Throw away the selected changes of an unstaged diff from the work tree (`git apply --reverse`).
    case discard

    var isReverse: Bool { self != .stage }
}

/// Builds patches that apply only some of a file's changes: whole hunks or single lines. Git has no
/// command for this, so every Git GUI writes a patch by hand and feeds it to `git apply`.
///
/// Unselected lines are neutralised so the patch still matches the file it is applied to:
/// - Staging forward: an unselected deletion stays as context (the line is kept) and an unselected
///   addition is left out (it is not in the index yet).
/// - Applying in reverse (unstage, discard): an unselected addition stays as context (it is in the file
///   and must stay) and an unselected deletion is left out (it is already gone from the file).
public enum PatchBuilder {
    /// Every changed line of one hunk.
    public static func hunkSelection(of file: FileDiff, hunk index: Int) -> Set<LineSelection> {
        guard file.hunks.indices.contains(index) else { return [] }
        var selection = Set<LineSelection>()
        for (lineIndex, line) in file.hunks[index].lines.enumerated() where line.isChange {
            selection.insert(LineSelection(hunk: index, line: lineIndex))
        }
        return selection
    }

    /// Every changed line of the file.
    public static func fullSelection(of file: FileDiff) -> Set<LineSelection> {
        file.hunks.indices.reduce(into: Set<LineSelection>()) { $0.formUnion(hunkSelection(of: file, hunk: $1)) }
    }

    /// Whether `file` can be staged or discarded line by line. Binary files, renames, copies and mode
    /// changes can only be handled as a whole.
    public static func supportsPartialChanges(_ file: FileDiff) -> Bool {
        guard !file.isBinary, !file.hunks.isEmpty else { return false }
        switch file.change {
        case .added, .modified: break
        case .deleted: return true
        case .renamed, .copied: return false
        }
        return file.oldMode == file.newMode || file.change == .added
    }

    /// The patch for the selected lines, or nil when the selection holds no changed lines or the file
    /// can't be patched line by line.
    public static func patch(for file: FileDiff, selecting selection: Set<LineSelection>, intent: PatchIntent) -> String? {
        guard supportsPartialChanges(file) else { return nil }
        let reverse = intent.isReverse
        let totalChanges = fullSelection(of: file).count
        let selectedChanges = selection.intersection(fullSelection(of: file)).count
        guard selectedChanges > 0 else { return nil }
        let everythingSelected = selectedChanges == totalChanges

        let path = file.path
        // A deleted file can only be reversed as a whole: the file isn't there to patch.
        if file.change == .deleted, reverse, !everythingSelected { return nil }

        let createsFile = file.change == .added && (!reverse || everythingSelected)
        let deletesFile = file.change == .deleted && everythingSelected

        var header = "diff --git \(quoted("a/" + path)) \(quoted("b/" + path))\n"
        if createsFile { header += "new file mode \(file.newMode ?? "100644")\n" }
        if deletesFile { header += "deleted file mode \(file.oldMode ?? "100644")\n" }
        header += createsFile ? "--- /dev/null\n" : "--- \(quoted("a/" + path))\n"
        header += deletesFile ? "+++ /dev/null\n" : "+++ \(quoted("b/" + path))\n"

        var body = ""
        var delta = 0 // new minus old line count of the hunks already written
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            var lines: [String] = []
            var oldCount = 0, newCount = 0
            var previousKept = false
            for (lineIndex, line) in hunk.lines.enumerated() {
                let selected = selection.contains(LineSelection(hunk: hunkIndex, line: lineIndex))
                switch line.kind {
                case .context:
                    lines.append(" " + line.text); oldCount += 1; newCount += 1; previousKept = true
                case .addition:
                    if selected {
                        lines.append("+" + line.text); newCount += 1; previousKept = true
                    } else if reverse {
                        lines.append(" " + line.text); oldCount += 1; newCount += 1; previousKept = true
                    } else {
                        previousKept = false
                    }
                case .deletion:
                    if selected {
                        lines.append("-" + line.text); oldCount += 1; previousKept = true
                    } else if !reverse {
                        lines.append(" " + line.text); oldCount += 1; newCount += 1; previousKept = true
                    } else {
                        previousKept = false
                    }
                case .noNewlineAtEnd:
                    if previousKept { lines.append("\\" + line.text) }
                }
            }
            // Skip hunks with nothing to apply.
            guard lines.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { continue }

            let oldStart: Int, newStart: Int
            if createsFile {
                (oldStart, newStart) = (0, 1)
            } else if reverse {
                // The file being patched is the "new" side, whose positions the diff already gives.
                (oldStart, newStart) = (max(0, hunk.newStart - delta), hunk.newStart)
            } else {
                (oldStart, newStart) = (hunk.oldStart, hunk.oldStart + delta)
            }
            body += "@@ -\(range(oldStart, createsFile ? 0 : oldCount)) +\(range(newStart, newCount)) @@\n"
            body += lines.joined(separator: "\n") + "\n"
            delta += newCount - oldCount
        }
        return body.isEmpty ? nil : header + body
    }

    private static func range(_ start: Int, _ count: Int) -> String {
        count == 1 ? "\(start)" : "\(start),\(count)"
    }

    /// Quotes a path the way git writes it when it holds characters that need escaping.
    static func quoted(_ path: String) -> String {
        let needsQuotes = path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f }
        guard needsQuotes else { return path }
        var result = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    result += "\\" + String(scalar.value, radix: 8).leftPadded(to: 3)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}

extension DiffLine {
    /// True for additions and deletions.
    public var isChange: Bool { kind == .addition || kind == .deletion }
}
