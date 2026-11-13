import Foundation
import GitEngine
import Testing
@testable import StrongholdCore

@Suite("Blame rows")
struct BlameRowsTests {
    private func blame(_ commitIDs: [String], text: (Int) -> String = { "line \($0)" }) -> Blame {
        let lines = commitIDs.enumerated().map { index, id in
            BlameLine(commitID: id, originalLineNumber: index + 1, lineNumber: index + 1, originalPath: "f", text: text(index))
        }
        return Blame(path: "f", lines: lines, commits: [:])
    }

    @Test func everyLineIsARowAndRunsAreLabelledOnTheirFirstTwoLines() {
        let rows = BlameRows(blame(["a", "a", "a", "b", "a", "a"]))
        #expect(rows.rows.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(rows.rows.map(\.lineNumber) == [1, 2, 3, 4, 5, 6])
        #expect(rows.rows.map(\.commitID) == ["a", "a", "a", "b", "a", "a"])
        #expect(rows.rows.map(\.gutter) == [.summary, .details, .none, .summaryAndDetails, .summary, .details])
        #expect(rows.rows.map(\.runIndex) == [0, 0, 0, 1, 2, 2])
        #expect(rows.rows.map(\.isRunStart) == [true, false, false, true, true, false])
        #expect(rows.hiddenLines == 0)
    }

    @Test func aLongRunFromOneCommitIsStillOneRowPerLine() {
        let rows = BlameRows(blame(Array(repeating: "a", count: 20_000)), lineLimit: .max)
        #expect(rows.rows.count == 20_000)
        #expect(rows.rows.filter(\.isRunStart).count == 1)
        #expect(rows.rows.filter { $0.gutter != .none }.count == 2)
        #expect(Set(rows.rows.map(\.runIndex)) == [0])
    }

    @Test func cutsAtTheLineLimitAndCountsWhatIsHidden() {
        let ids = Array(repeating: "a", count: 4_500) + ["b"]
        let limited = BlameRows(blame(ids))
        #expect(BlameRows.defaultLineLimit == 4_000)
        #expect(limited.rows.count == 4_000)
        #expect(limited.hiddenLines == 501)
        #expect(limited.rows.last?.id == 3_999)

        let all = BlameRows(blame(ids), lineLimit: .max)
        #expect(all.rows.count == 4_501)
        #expect(all.hiddenLines == 0)
        #expect(all.rows.last?.gutter == .summaryAndDetails)
    }

    @Test func aCutDoesNotChangeTheLabelOfTheLastShownLine() {
        // Line 1 starts a run that carries on past the cut, so it keeps the summary-only label.
        let rows = BlameRows(blame(["a", "b", "b", "b"]), lineLimit: 2)
        #expect(rows.rows.map(\.gutter) == [.summaryAndDetails, .summary])
        #expect(rows.hiddenLines == 2)
        #expect(BlameRows(blame(["a", "b"]), lineLimit: 0).rows.isEmpty)
        #expect(BlameRows(blame(["a", "b"]), lineLimit: -3).hiddenLines == 2)
    }

    @Test func textIsPreparedForDrawing() {
        let long = String(repeating: "x", count: DiffRows.maxLineLength + 10)
        let rows = BlameRows(blame(["a", "a", "a"]) { ["\tindented\r", "", long][$0] })
        #expect(rows.rows[0].text == "    indented")
        #expect(rows.rows[0].isClipped == false)
        #expect(rows.rows[1].text == "")
        #expect(rows.rows[2].isClipped)
        #expect(rows.rows[2].text.count == DiffRows.maxLineLength + 1)
        #expect(rows.longestLine == DiffRows.maxLineLength + 1)
    }

    @Test func emptyBlameHasNoRows() {
        let rows = BlameRows(Blame(path: "f", lines: [], commits: [:]))
        #expect(rows.rows.isEmpty)
        #expect(rows.hiddenLines == 0)
        #expect(rows.longestLine == 0)
    }
}
