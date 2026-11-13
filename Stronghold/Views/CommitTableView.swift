import AppKit
import GitEngine
import StrongholdCore
import SwiftUI

/// The commit list with its branch graph. It's an `NSTableView` because the graph needs rows with no gap
/// between them so the lines join up, and because histories run to tens of thousands of rows.
struct CommitTableView: NSViewRepresentable {
    let rows: [HistoryModel.Row]
    let graph: CommitGraph?
    let selectedID: String?
    let select: (String?) -> Void
    let loadMore: () -> Void

    static let rowHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier("history.table")
        table.setAccessibilityLabel("Commits")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.width
            if column == .message { tableColumn.resizingMask = .autoresizingMask }
            table.addTableColumn(tableColumn)
        }

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        let idsChanged = coordinator.rowIDs != rows.map(\.id) || coordinator.graph != graph
        if idsChanged {
            coordinator.rows = rows
            coordinator.rowIDs = rows.map(\.id)
            coordinator.graph = graph
            coordinator.graphWidth = graph.map { CGFloat(max($0.width, 1)) * GraphCellView.laneWidth + 8 } ?? 0
            table.reloadData()
        }
        // Follow the model's selection without echoing it back.
        let wanted = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        if table.selectedRow != (wanted ?? -1) {
            coordinator.isApplyingSelection = true
            if let wanted {
                table.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
                table.scrollRowToVisible(wanted)
            } else {
                table.deselectAll(nil)
            }
            coordinator.isApplyingSelection = false
        }
    }

    enum Column: String, CaseIterable {
        case message, author, date, id

        var title: String {
            switch self {
            case .message: "Message"
            case .author: "Author"
            case .date: "Date"
            case .id: "Commit"
            }
        }

        var width: CGFloat {
            switch self {
            case .message: 520
            case .author: 150
            case .date: 140
            case .id: 72
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .message: 200
            case .author: 80
            case .date: 90
            case .id: 60
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: CommitTableView?
        weak var table: NSTableView?
        var rows: [HistoryModel.Row] = []
        var rowIDs: [String] = []
        var graph: CommitGraph?
        var graphWidth: CGFloat = 0
        var isApplyingSelection = false

        private static let dateFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).year().hour().minute()

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), rows.indices.contains(row) else { return nil }
            // Ask for the next page a little before the end comes into view.
            if row >= rows.count - 40 { parent?.loadMore() }
            let item = rows[row]
            switch column {
            case .message:
                let view = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? GraphCellView) ?? GraphCellView()
                view.identifier = tableColumn.identifier
                view.configure(commit: item.commit, graphRow: graph?.rows[safe: row], graphWidth: graphWidth)
                return view
            case .author:
                return textCell(tableView, tableColumn, item.commit.author.name, secondary: false)
            case .date:
                return textCell(tableView, tableColumn, item.commit.author.date.formatted(Self.dateFormat), secondary: true)
            case .id:
                let cell = textCell(tableView, tableColumn, item.commit.shortID, secondary: true)
                cell.textField?.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                return cell
            }
        }

        private func textCell(_ tableView: NSTableView, _ column: NSTableColumn, _ text: String, secondary: Bool) -> NSTableCellView {
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = column.identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = text
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table else { return }
            let row = table.selectedRow
            parent?.select(rows.indices.contains(row) ? rows[row].id : nil)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let commit = rows[table.clickedRow].commit
            menu.addItem(item("Copy Commit ID", commit.id))
            menu.addItem(item("Copy Short ID", commit.shortID))
            menu.addItem(item("Copy Message", commit.message))
        }

        private func item(_ title: String, _ value: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            return item
        }

        @objc private func copy(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}

/// The message column: the branch graph, ref labels, then the commit summary, all drawn directly.
final class GraphCellView: NSTableCellView {
    static let laneWidth: CGFloat = 14
    static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink,
                                     .systemTeal, .systemYellow, .systemRed]

    private var commit: Commit?
    private var graphRow: CommitGraph.Row?
    private var graphWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    /// Text colour that stays readable on a selected row.
    private var primaryText: NSColor { backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor }

    func configure(commit: Commit, graphRow: CommitGraph.Row?, graphWidth: CGFloat) {
        self.commit = commit
        self.graphRow = graphRow
        self.graphWidth = graphWidth
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let refs = commit.decorations.map(\.name).joined(separator: ", ")
        setAccessibilityLabel(refs.isEmpty ? commit.summary : "\(commit.summary), \(refs)")
        needsDisplay = true
    }

    static func color(_ index: Int) -> NSColor { palette[index % palette.count] }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let height = bounds.height
        let middle = height / 2
        var x: CGFloat = 2

        if let row = graphRow {
            func laneX(_ lane: Int) -> CGFloat { 2 + Self.laneWidth / 2 + CGFloat(lane) * Self.laneWidth }
            func stroke(_ segment: CommitGraph.Segment, fromY: CGFloat, toY: CGFloat) {
                let path = NSBezierPath()
                path.lineWidth = 2
                path.lineCapStyle = .round
                let start = NSPoint(x: laneX(segment.from), y: fromY), end = NSPoint(x: laneX(segment.to), y: toY)
                path.move(to: start)
                if segment.from == segment.to {
                    path.line(to: end)
                } else {
                    let bend = (toY - fromY) / 2
                    path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: fromY + bend),
                               controlPoint2: NSPoint(x: end.x, y: toY - bend))
                }
                Self.color(segment.color).setStroke()
                path.stroke()
            }
            for segment in row.top { stroke(segment, fromY: 0, toY: middle) }
            for segment in row.bottom { stroke(segment, fromY: middle, toY: height) }
            let radius: CGFloat = row.isMerge ? 3.5 : 4.5
            let dot = NSBezierPath(ovalIn: NSRect(x: laneX(row.lane) - radius, y: middle - radius, width: radius * 2, height: radius * 2))
            if row.isMerge {
                NSColor.textBackgroundColor.setFill()
                dot.fill()
                dot.lineWidth = 2
                Self.color(row.color).setStroke()
                dot.stroke()
            } else {
                Self.color(row.color).setFill()
                dot.fill()
            }
            x = graphWidth + 4
        } else {
            // Search results and file histories aren't connected, so just mark each commit.
            let dot = NSBezierPath(ovalIn: NSRect(x: 6, y: middle - 4, width: 8, height: 8))
            Self.color(0).setFill()
            dot.fill()
            x = 22
        }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        for decoration in commit.decorations {
            let isHead = decoration.isHead
            let isTag = decoration.kind == .tag
            let isRemote = decoration.kind == .remoteBranch || decoration.kind == .other
            let text = NSAttributedString(string: (isTag ? "🏷 " : "") + decoration.name, attributes: [
                .font: font,
                .foregroundColor: primaryText,
            ])
            let size = text.size()
            let pill = NSRect(x: x, y: middle - 8, width: size.width + 10, height: 16)
            guard pill.maxX < bounds.width - 40 else { break }
            let shape = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
            let tint: NSColor = isTag ? .systemYellow : (isRemote ? .systemGray : .controlAccentColor)
            tint.withAlphaComponent(isHead ? 0.35 : 0.18).setFill()
            shape.fill()
            if isHead {
                tint.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }
            text.draw(at: NSPoint(x: pill.minX + 5, y: middle - size.height / 2))
            x = pill.maxX + 5
        }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let summary = NSAttributedString(string: commit.summary, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: primaryText,
            .paragraphStyle: style,
        ])
        let lineHeight = summary.size().height
        summary.draw(with: NSRect(x: x, y: middle - lineHeight / 2, width: max(0, bounds.width - x - 4), height: lineHeight),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
