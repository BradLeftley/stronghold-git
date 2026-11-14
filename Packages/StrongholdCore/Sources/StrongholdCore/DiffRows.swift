import Foundation
import GitEngine

/// One row of the diff viewer: a hunk header or a line.
public enum DiffRow: Identifiable, Equatable, Sendable {
    case hunk(index: Int, header: String, section: String)
    case line(DiffRowLine)

    public var id: String {
        switch self {
        case .hunk(let index, _, _): "h\(index)"
        case .line(let line): "h\(line.selection.hunk)l\(line.selection.line)"
        }
    }
}

public struct DiffRowLine: Equatable, Sendable {
    public var selection: LineSelection
    public var kind: DiffLine.Kind
    /// The text ready to draw: tabs expanded, very long lines cut.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// True when the line is cut short for display.
    public var isClipped: Bool

    /// Additions and deletions can be selected.
    public var isSelectable: Bool { kind == .addition || kind == .deletion }
}

/// Turns a `FileDiff` into rows for the viewer, capping how much is drawn so a huge diff stays responsive.
public struct DiffRows: Equatable, Sendable {
    public var rows: [DiffRow]
    /// Changed lines left out because of `lineLimit`.
    public var hiddenLines: Int
    /// The longest drawn line, in characters.
    public var longestLine: Int

    public static let defaultLineLimit = 4000
    public static let maxLineLength = 1500
    public static let tabWidth = 4

    public init(_ file: FileDiff, lineLimit: Int = DiffRows.defaultLineLimit) {
        var rows: [DiffRow] = []
        var drawn = 0
        var hidden = 0
        var longest = 0
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            if drawn >= lineLimit {
                hidden += hunk.lines.count
                continue
            }
            rows.append(.hunk(index: hunkIndex, header: hunk.header, section: hunk.section))
            for (lineIndex, line) in hunk.lines.enumerated() {
                guard drawn < lineLimit else { hidden += 1; continue }
                if line.kind == .noNewlineAtEnd { continue }
                let (text, clipped) = Self.displayText(line.text)
                longest = max(longest, text.count)
                rows.append(.line(DiffRowLine(selection: LineSelection(hunk: hunkIndex, line: lineIndex), kind: line.kind,
                                              text: text, oldNumber: line.oldLineNumber, newNumber: line.newLineNumber,
                                              isClipped: clipped)))
                drawn += 1
            }
        }
        self.rows = rows
        self.hiddenLines = hidden
        self.longestLine = longest
    }

    /// Expands tabs, drops a trailing carriage return and cuts very long lines.
    public static func displayText(_ text: String) -> (String, Bool) {
        var text = text
        if text.hasSuffix("\r") { text.removeLast() }
        if text.contains("\t") { text = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth)) }
        if text.count > maxLineLength { return (String(text.prefix(maxLineLength)) + "…", true) }
        return (text, false)
    }
}
