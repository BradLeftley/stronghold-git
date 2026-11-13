import Foundation
import GitEngine

/// What the blame gutter shows on one line. A run of lines from one commit shows the summary on its first
/// line and the ID, author and date on its second; a one-line run shows both on its only line, which
/// is drawn taller to fit them.
public enum BlameGutter: Equatable, Sendable {
    case summary
    case details
    case summaryAndDetails
    case none
}

/// One line of the blame viewer. Each line is its own row, so a long run from one commit is drawn lazily.
public struct BlameRow: Identifiable, Equatable, Sendable {
    /// The line's index in `Blame.lines`.
    public var id: Int
    public var commitID: String
    public var lineNumber: Int
    /// The text ready to draw: tabs expanded, very long lines cut.
    public var text: String
    public var isClipped: Bool
    /// The run of lines from one commit this line is in, counted from the top, for striping.
    public var runIndex: Int
    public var gutter: BlameGutter
    /// The first line of a run, where a separator is drawn.
    public var isRunStart: Bool { gutter == .summary || gutter == .summaryAndDetails }
}

/// Turns a `Blame` into one row per line, capping how many are drawn so a huge file stays responsive.
public struct BlameRows: Equatable, Sendable {
    public var rows: [BlameRow]
    /// Lines left out because of `lineLimit`.
    public var hiddenLines: Int
    /// The longest drawn line, in characters.
    public var longestLine: Int

    public static let defaultLineLimit = DiffRows.defaultLineLimit

    public init(_ blame: Blame, lineLimit: Int = BlameRows.defaultLineLimit) {
        let shown = min(blame.lines.count, max(lineLimit, 0))
        var rows: [BlameRow] = []
        rows.reserveCapacity(shown)
        var longest = 0
        var runIndex = -1
        var runStart = 0
        for index in 0..<shown {
            let line = blame.lines[index]
            let startsRun = index == 0 || blame.lines[index - 1].commitID != line.commitID
            if startsRun {
                runIndex += 1
                runStart = index
            }
            // Whether the run goes on past this line, looking at the whole file so a cut doesn't change labels.
            let continues = index + 1 < blame.lines.count && blame.lines[index + 1].commitID == line.commitID
            let gutter: BlameGutter = switch index - runStart {
            case 0: continues ? .summary : .summaryAndDetails
            case 1: .details
            default: .none
            }
            let (text, clipped) = DiffRows.displayText(line.text)
            longest = max(longest, text.count)
            rows.append(BlameRow(id: index, commitID: line.commitID, lineNumber: line.lineNumber, text: text,
                                 isClipped: clipped, runIndex: runIndex, gutter: gutter))
        }
        self.rows = rows
        self.hiddenLines = blame.lines.count - shown
        self.longestLine = longest
    }
}
