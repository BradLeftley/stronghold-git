import Foundation

/// The branch lines for a list of commits, laid out one row per commit for drawing next to the list.
///
/// Each row is split at its node into a top half and a bottom half. A line in the top half runs from a
/// lane at the row's top edge to a lane at its middle; a line in the bottom half runs from the middle to
/// the bottom edge. Rows drawn one under another join up into continuous branch lines.
public struct CommitGraph: Sendable, Equatable {
    public struct Segment: Sendable, Equatable, Hashable {
        public var from: Int
        public var to: Int
        /// An index into a palette. It belongs to the line, so a branch keeps one colour down the graph.
        public var color: Int

        public init(from: Int, to: Int, color: Int) {
            self.from = from
            self.to = to
            self.color = color
        }
    }

    public struct Row: Sendable, Equatable, Hashable {
        /// The lane the commit's dot sits in.
        public var lane: Int
        public var color: Int
        public var top: [Segment]
        public var bottom: [Segment]
        public var isMerge: Bool

        /// Lanes the row needs room for.
        public var width: Int {
            let lanes = (top + bottom).flatMap { [$0.from, $0.to] } + [lane]
            return (lanes.max() ?? 0) + 1
        }
    }

    public var rows: [Row]
    /// The widest row, for sizing the graph column.
    public var width: Int

    /// How many colours the layout cycles through.
    public static let paletteSize = 8

    /// Lays out `commits`, which must be in an order where children come before their parents (as
    /// `git log --topo-order` or `--date-order` give). Parents missing from the list keep a line running
    /// off the bottom, as when only the first page of history is loaded.
    public init(_ commits: [Commit]) {
        // Each lane waits for one commit: the parent the line above it leads to.
        var lanes: [String?] = []
        var laneColors: [Int] = []
        var nextColor = 0
        var rows: [Row] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }
        func takeColor() -> Int {
            defer { nextColor = (nextColor + 1) % Self.paletteSize }
            return nextColor
        }

        for commit in commits {
            let waiting = lanes.indices.filter { lanes[$0] == commit.id }
            let node: Int
            if let first = waiting.first {
                node = first
            } else {
                // A branch tip nothing above leads to: start a new line.
                node = freeLane()
                laneColors[node] = takeColor()
            }
            let nodeColor = laneColors[node]

            var top: [Segment] = []
            for (lane, expected) in lanes.enumerated() {
                guard let expected else { continue }
                if expected == commit.id {
                    top.append(Segment(from: lane, to: node, color: laneColors[lane]))
                } else {
                    top.append(Segment(from: lane, to: lane, color: laneColors[lane]))
                }
            }

            // Lines that ended at this commit are done; the node's lane carries on to the first parent.
            for lane in waiting { lanes[lane] = nil }
            var bottom: [Segment] = []
            var parentLanes: [(lane: Int, color: Int)] = []
            // Lanes this commit starts, which don't run straight down from above.
            var startedHere: Set<Int> = []
            for (index, parent) in commit.parents.enumerated() {
                if index == 0 {
                    lanes[node] = parent
                    laneColors[node] = nodeColor
                    parentLanes.append((node, nodeColor))
                    startedHere.insert(node)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    // A merge from a line that's already drawn: join it.
                    parentLanes.append((existing, laneColors[existing]))
                } else {
                    let lane = freeLane()
                    lanes[lane] = parent
                    laneColors[lane] = takeColor()
                    parentLanes.append((lane, laneColors[lane]))
                    startedHere.insert(lane)
                }
            }
            for (lane, expected) in lanes.enumerated() where expected != nil && !startedHere.contains(lane) {
                bottom.append(Segment(from: lane, to: lane, color: laneColors[lane]))
            }
            for parent in parentLanes {
                bottom.append(Segment(from: node, to: parent.lane, color: parent.color))
            }

            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }
            rows.append(Row(lane: node, color: nodeColor, top: top, bottom: bottom, isMerge: commit.parents.count > 1))
        }
        self.rows = rows
        self.width = rows.map(\.width).max() ?? 0
    }
}
