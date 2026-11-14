import GitEngine
import StrongholdCore
import SwiftUI

/// The right-hand side of the changes screen: the selected file's diff with hunk and line actions.
struct DiffPane: View {
    @Bindable var workingCopy: WorkingCopyModel
    @Binding var pendingDiscard: DiscardRequest?

    var body: some View {
        switch workingCopy.diff {
        case .none:
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a changed file to see what changed."))
                .accessibilityIdentifier("diff.empty")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .multiple(let count):
            ContentUnavailableView("\(count) Files Selected", systemImage: "doc.on.doc",
                                   description: Text("Select a single file to see its diff."))
        case .conflict:
            ContentUnavailableView("Merge Conflict", systemImage: "exclamationmark.triangle",
                                   description: Text("Resolve the conflict markers in your editor, then stage the file. A built-in merge editor is planned."))
                .accessibilityIdentifier("diff.conflict")
        case .noPreview(let message):
            ContentUnavailableView(message, systemImage: "doc")
                .accessibilityIdentifier("diff.noPreview")
        case .file(let file):
            VStack(spacing: 0) {
                DiffHeader(file: file, workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
                Divider()
                DiffTextView(file: file, workingCopy: workingCopy, pendingDiscard: $pendingDiscard)
            }
            .accessibilityIdentifier("diff.view")
        }
    }
}

private struct DiffHeader: View {
    let file: FileDiff
    @Bindable var workingCopy: WorkingCopyModel
    @Binding var pendingDiscard: DiscardRequest?

    private var area: ChangeArea? { workingCopy.focusedArea }
    private var picked: Int { workingCopy.lineSelection.count }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path).font(.headline).lineLimit(1).truncationMode(.head)
                HStack(spacing: 8) {
                    if case .renamed = file.change, let old = file.oldPath { Text("renamed from \(old)") }
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if workingCopy.supportsLineSelection {
                if picked > 0 {
                    Text("\(picked) \(picked == 1 ? "line" : "lines") selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(area == .staged ? "Unstage Lines" : "Stage Lines") {
                        Task { await workingCopy.applySelectedLines() }
                    }
                    .accessibilityIdentifier("diff.applyLines")
                    if area == .unstaged {
                        Button("Discard Lines…", role: .destructive) { pendingDiscard = .lines(picked) }
                            .accessibilityIdentifier("diff.discardLines")
                    }
                    Button("Clear") { workingCopy.lineSelection = [] }
                } else {
                    Text("Click lines to select them")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            } else if area == .staged || area == .unstaged {
                Text("This kind of change is staged as a whole file")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Diff text

private struct DiffTextView: View {
    let file: FileDiff
    @Bindable var workingCopy: WorkingCopyModel
    @Binding var pendingDiscard: DiscardRequest?
    @State private var lineLimit = DiffRows.defaultLineLimit

    private static let characterWidth: CGFloat = 7.4
    private static let gutterWidth: CGFloat = 22 + 46 + 46 + 18

    var body: some View {
        let rows = DiffRows(file, lineLimit: lineLimit)
        let contentWidth = Self.gutterWidth + CGFloat(rows.longestLine) * Self.characterWidth + 24
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.rows) { row in
                        switch row {
                        case .hunk(let index, let header, _):
                            HunkHeaderRow(index: index, header: header, workingCopy: workingCopy,
                                          canAct: workingCopy.supportsLineSelection, pendingDiscard: $pendingDiscard)
                                .frame(minWidth: max(contentWidth, proxy.size.width), alignment: .leading)
                        case .line(let line):
                            LineRow(line: line, isPicked: workingCopy.lineSelection.contains(line.selection),
                                    canPick: workingCopy.supportsLineSelection) {
                                workingCopy.toggleLine(line.selection)
                            }
                            .frame(minWidth: max(contentWidth, proxy.size.width), alignment: .leading)
                        }
                    }
                    if rows.hiddenLines > 0 {
                        HStack {
                            Text("\(rows.hiddenLines) more lines are not shown.")
                            Button("Show All") { lineLimit = .max }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(.background)
        .accessibilityIdentifier("diff.text")
    }
}

private struct HunkHeaderRow: View {
    let index: Int
    let header: String
    @Bindable var workingCopy: WorkingCopyModel
    let canAct: Bool
    @Binding var pendingDiscard: DiscardRequest?

    var body: some View {
        // The buttons come first so they stay in view when a wide diff scrolls sideways.
        HStack(spacing: 10) {
            if canAct {
                Button(workingCopy.focusedArea == .staged ? "Unstage Hunk" : "Stage Hunk") {
                    Task { await workingCopy.applyHunk(index) }
                }
                .accessibilityIdentifier("hunk.apply.\(index)")
                if workingCopy.focusedArea == .unstaged {
                    Button("Discard Hunk…", role: .destructive) { pendingDiscard = .hunk(index) }
                        .accessibilityIdentifier("hunk.discard.\(index)")
                }
                Button("Select") { workingCopy.toggleHunk(index) }
                    .help("Select or deselect every changed line in this hunk")
            }
            Text(header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
    }
}

struct LineRow: View {
    let line: DiffRowLine
    let isPicked: Bool
    let canPick: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // The gutter: a tick for picked lines, then both line numbers.
            ZStack {
                if line.isSelectable && canPick {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isPicked ? Color.accentColor : Color.secondary.opacity(0.5))
                }
            }
            .frame(width: 22)
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
                .padding(.trailing, 6)
            Text(marker).frame(width: 12).foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.vertical, 1)
        .background(background)
        .overlay(alignment: .leading) {
            if isPicked { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if line.isSelectable && canPick { toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel) \(line.text)")
        .accessibilityAddTraits(line.isSelectable && canPick ? .isButton : [])
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        default: .secondary
        }
    }

    private var kindLabel: String {
        switch line.kind {
        case .addition: "Added"
        case .deletion: "Removed"
        default: "Unchanged"
        }
    }

    private var background: Color {
        let base: Color = switch line.kind {
        case .addition: .green.opacity(0.16)
        case .deletion: .red.opacity(0.16)
        default: .clear
        }
        return isPicked ? Color.accentColor.opacity(0.22) : base
    }
}

// MARK: - Read-only diff

/// A diff with no staging actions, for commits in the history.
struct ReadOnlyDiffView: View {
    let file: FileDiff
    @State private var lineLimit = DiffRows.defaultLineLimit

    private static let characterWidth: CGFloat = 7.4
    private static let gutterWidth: CGFloat = 22 + 46 + 46 + 18

    var body: some View {
        let rows = DiffRows(file, lineLimit: lineLimit)
        let contentWidth = Self.gutterWidth + CGFloat(rows.longestLine) * Self.characterWidth + 24
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.rows) { row in
                        switch row {
                        case .hunk(_, let header, _):
                            Text(header)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: max(contentWidth, proxy.size.width), alignment: .leading)
                                .background(Color.accentColor.opacity(0.10))
                        case .line(let line):
                            LineRow(line: line, isPicked: false, canPick: false) {}
                                .frame(minWidth: max(contentWidth, proxy.size.width), alignment: .leading)
                        }
                    }
                    if rows.hiddenLines > 0 {
                        HStack {
                            Text("\(rows.hiddenLines) more lines are not shown.")
                            Button("Show All") { lineLimit = .max }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(.background)
        .accessibilityIdentifier("history.diff")
    }
}
