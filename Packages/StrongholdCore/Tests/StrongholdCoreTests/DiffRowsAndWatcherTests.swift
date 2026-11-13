import Foundation
import GitEngine
import GitTestSupport
import Testing
@testable import StrongholdCore

@Suite("Diff rows")
struct DiffRowsTests {
    private func file(_ lines: [DiffLine], hunks: Int = 1) -> FileDiff {
        FileDiff(oldPath: "f", newPath: "f", change: .modified,
                 hunks: (0..<hunks).map { DiffHunk(oldStart: 1 + $0 * 100, oldCount: 1, newStart: 1 + $0 * 100, newCount: 1, section: "func x()", lines: lines) })
    }

    @Test func buildsAHeaderRowThenOneRowPerLine() {
        let rows = DiffRows(file([
            DiffLine(kind: .context, text: "a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(kind: .deletion, text: "b", oldLineNumber: 2),
            DiffLine(kind: .addition, text: "c", newLineNumber: 2),
            DiffLine(kind: .noNewlineAtEnd, text: " No newline at end of file"),
        ]))
        #expect(rows.rows.count == 4, "the no-newline marker is not drawn")
        guard case .hunk(let index, let header, let section) = rows.rows[0] else { Issue.record("no header"); return }
        #expect(index == 0 && header == "@@ -1 +1 @@ func x()" && section == "func x()")
        guard case .line(let deletion) = rows.rows[2] else { Issue.record("no line"); return }
        #expect(deletion.isSelectable && deletion.selection == LineSelection(hunk: 0, line: 1) && deletion.oldNumber == 2)
        guard case .line(let context) = rows.rows[1] else { Issue.record("no line"); return }
        #expect(!context.isSelectable)
        #expect(rows.hiddenLines == 0)
    }

    @Test func rowIdentifiersAreUnique() {
        let rows = DiffRows(file([DiffLine(kind: .addition, text: "x", newLineNumber: 1)], hunks: 3))
        #expect(Set(rows.rows.map(\.id)).count == rows.rows.count)
    }

    @Test func tabsAreExpandedAndCarriageReturnsDropped() {
        let (text, clipped) = DiffRows.displayText("\tindent\r")
        #expect(text == "    indent" && !clipped)
    }

    @Test func veryLongLinesAreClipped() {
        let (text, clipped) = DiffRows.displayText(String(repeating: "x", count: 5000))
        #expect(clipped && text.count == DiffRows.maxLineLength + 1 && text.hasSuffix("…"))
    }

    @Test func hugeDiffsAreCapped() {
        var lines: [DiffLine] = []
        for n in 1...50 as ClosedRange<Int> { lines.append(DiffLine(kind: .addition, text: "line \(n)", newLineNumber: n)) }
        let rows = DiffRows(file(lines, hunks: 4), lineLimit: 120)
        // Three hunks fit (150 lines would not, the cap cuts inside the third); the fourth is hidden.
        let drawnLines = rows.rows.filter { if case .line = $0 { true } else { false } }.count
        #expect(drawnLines == 120)
        #expect(rows.hiddenLines == 80)
        #expect(rows.longestLine == "line 50".count)
    }
}

@Suite("Repository watcher")
struct WatcherTests {
    private let root = URL(fileURLWithPath: "/tmp/work", isDirectory: true)

    @Test func ordinaryFilesAndGitStateMatterButGitBookkeepingDoesNot() {
        func relevant(_ path: String) -> Bool { RepositoryWatcher.isRelevant("/tmp/work/" + path, root: root) }
        #expect(relevant("src/main.swift"))
        #expect(relevant(".gitignore"))
        #expect(relevant(".git/index"))
        #expect(relevant(".git/HEAD"))
        #expect(relevant(".git/refs/heads/main"))
        #expect(relevant(".git/MERGE_HEAD"))
        #expect(!relevant(".git/index.lock"))
        #expect(!relevant(".git/objects/ab/cdef"))
        #expect(!relevant(".git/logs/HEAD"))
        #expect(!relevant(".git/FETCH_HEAD"))
        #expect(!relevant(".git"))
        #expect(!relevant(".git/hooks/pre-commit"))
    }

    @Test func firesWhenAFileChangesAndStopsAfterStop() async throws {
        let tmp = try await TemporaryRepository()
        let hits = Hits()
        let watcher = RepositoryWatcher(root: tmp.url, latency: 0.1) { hits.add() }
        watcher.start()
        watcher.start() // starting twice is harmless
        try await Task.sleep(for: .milliseconds(300))
        try tmp.write("new.txt", "hello")
        try await waitUntil { hits.count > 0 }
        #expect(hits.count > 0)

        watcher.stop()
        try await Task.sleep(for: .milliseconds(300))
        let before = hits.count
        try tmp.write("another.txt", "x")
        try await Task.sleep(for: .milliseconds(800))
        #expect(hits.count == before)
    }

    @Test func aRepositoryModelRefreshesItselfWhenWatched() async throws {
        let tmp = try await TemporaryRepository()
        try await tmp.commit("init", files: ["a.txt": "1\n"])
        let model = await RepositoryModel(repository: tmp.repository)
        await model.refresh()
        await model.startWatching()
        try await Task.sleep(for: .milliseconds(400))
        try tmp.write("a.txt", "2\n")
        try await waitUntil(timeout: 8) { await model.status.entries.contains { $0.path == "a.txt" } }
        #expect(await model.status.entries.map(\.path) == ["a.txt"])
        await model.stopWatching()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
