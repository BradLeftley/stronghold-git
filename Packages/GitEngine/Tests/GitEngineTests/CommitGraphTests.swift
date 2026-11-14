import Foundation
import Testing
@testable import GitEngine

@Suite("Commit graph layout")
struct CommitGraphTests {
    private func commit(_ id: String, _ parents: String...) -> Commit {
        let signature = Signature(name: "A", email: "a@example.com", date: Date(timeIntervalSince1970: 0))
        return Commit(id: id, parents: parents, author: signature, committer: signature, message: id)
    }

    private func seg(_ from: Int, _ to: Int, _ color: Int) -> CommitGraph.Segment {
        CommitGraph.Segment(from: from, to: to, color: color)
    }

    @Test func emptyHistoryHasNoRows() {
        let graph = CommitGraph([])
        #expect(graph.rows.isEmpty)
        #expect(graph.width == 0)
    }

    @Test func linearHistoryStaysInOneLane() {
        let graph = CommitGraph([commit("c", "b"), commit("b", "a"), commit("a")])
        #expect(graph.width == 1)
        #expect(graph.rows.map(\.lane) == [0, 0, 0])
        #expect(graph.rows[0].top.isEmpty)
        #expect(graph.rows[0].bottom == [seg(0, 0, 0)])
        #expect(graph.rows[1].top == [seg(0, 0, 0)])
        #expect(graph.rows[1].bottom == [seg(0, 0, 0)])
        #expect(graph.rows[2].top == [seg(0, 0, 0)])
        #expect(graph.rows[2].bottom.isEmpty, "a root commit has no line below it")
    }

    @Test func branchAndMergeUseTwoLanesAndJoinAtTheForkPoint() {
        // m merges f into c; both branched from b.
        let graph = CommitGraph([commit("m", "c", "f"), commit("c", "b"), commit("f", "b"), commit("b", "a"), commit("a")])
        let m = graph.rows[0], c = graph.rows[1], f = graph.rows[2], b = graph.rows[3], a = graph.rows[4]
        #expect(graph.width == 2)

        #expect(m.isMerge)
        #expect(m.lane == 0)
        #expect(m.bottom == [seg(0, 0, 0), seg(0, 1, 1)])

        #expect(c.lane == 0)
        #expect(c.top == [seg(0, 0, 0), seg(1, 1, 1)])
        #expect(Set(c.bottom) == [seg(0, 0, 0), seg(1, 1, 1)])

        #expect(f.lane == 1, "the merged branch keeps its own lane")
        #expect(f.color == 1, "and its own colour")
        #expect(Set(f.bottom) == [seg(0, 0, 0), seg(1, 1, 1)])

        #expect(b.lane == 0)
        #expect(b.top == [seg(0, 0, 0), seg(1, 0, 1)], "the branch line bends into its fork point")
        #expect(b.bottom == [seg(0, 0, 0)])
        #expect(b.width == 2)

        #expect(a.top == [seg(0, 0, 0)])
        #expect(a.width == 1, "freed lanes on the right are dropped")
    }

    @Test func separateBranchTipsGetTheirOwnLanesAndColours() {
        let graph = CommitGraph([commit("x", "a"), commit("y", "a"), commit("a")])
        #expect(graph.rows.map(\.lane) == [0, 1, 0])
        #expect(graph.rows[0].color != graph.rows[1].color)
        #expect(graph.rows[1].top == [seg(0, 0, 0)], "nothing leads into a new tip")
        #expect(Set(graph.rows[1].bottom) == [seg(0, 0, 0), seg(1, 1, 1)])
        #expect(graph.rows[2].top == [seg(0, 0, 0), seg(1, 0, 1)])
    }

    @Test func mergingALineThatsAlreadyDrawnJoinsIt() {
        // x is waiting for q in lane 0 when m merges q too.
        let graph = CommitGraph([commit("x", "q"), commit("m", "p", "q"), commit("p", "q"), commit("q")])
        let m = graph.rows[1]
        #expect(m.lane == 1)
        #expect(Set(m.bottom) == [seg(0, 0, 0), seg(1, 1, 1), seg(1, 0, 0)])
        #expect(graph.rows[3].lane == 0)
        #expect(graph.width == 2)
    }

    @Test func parentsOutsideTheListKeepALineRunningOffTheBottom() {
        let graph = CommitGraph([commit("c", "b"), commit("b", "a")])
        #expect(graph.rows[1].bottom == [seg(0, 0, 0)])
    }

    @Test func freedLanesAreReused() {
        // Lane 1 is freed when f reaches b; the later tip t reuses it.
        let graph = CommitGraph([commit("m", "b", "f"), commit("f", "b"), commit("b", "a"), commit("t", "a"), commit("a")])
        #expect(graph.rows[1].lane == 1)
        #expect(graph.rows[3].lane == 1)
        #expect(graph.width == 2)
    }

    @Test func coloursCycleThroughThePalette() {
        var commits = (0..<CommitGraph.paletteSize + 2).map { commit("tip\($0)", "root") }
        commits.append(commit("root"))
        let graph = CommitGraph(commits)
        #expect(graph.rows.allSatisfy { (0..<CommitGraph.paletteSize).contains($0.color) })
        #expect(graph.rows[CommitGraph.paletteSize].color == graph.rows[0].color)
        #expect(graph.width == CommitGraph.paletteSize + 2)
    }

    @Test func octopusMergeOpensALanePerParent() {
        let graph = CommitGraph([commit("o", "a", "b", "c"), commit("a", "r"), commit("b", "r"), commit("c", "r"), commit("r")])
        #expect(graph.rows[0].bottom.count == 3)
        #expect(graph.rows.map(\.lane) == [0, 0, 1, 2, 0])
        #expect(graph.rows[4].top.count == 3)
    }

    @Test func largeHistoryLaysOutQuickly() {
        // 20,000 commits with a side branch every 10 commits.
        var commits: [Commit] = []
        let count = 20_000
        for index in 0..<count {
            let parent = index + 1 < count ? "c\(index + 1)" : nil
            if index % 10 == 0, let parent, index + 2 < count {
                commits.append(commit("c\(index)", parent, "s\(index)"))
            } else {
                commits.append(parent.map { commit("c\(index)", $0) } ?? commit("c\(index)"))
            }
            if index % 10 == 1 { commits.append(commit("s\(index - 1)", "c\(index + 1)")) }
        }
        let start = Date()
        let graph = CommitGraph(commits)
        #expect(graph.rows.count == commits.count)
        #expect(graph.width <= 3)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
