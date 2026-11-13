import GitEngine
import SwiftUI

/// A plain commit list. The graph view replaces it in the history work.
struct HistoryView: View {
    let commits: [Commit]
    @State private var selection: Commit.ID?

    var body: some View {
        if commits.isEmpty {
            ContentUnavailableView("No Commits Yet", systemImage: "clock",
                                   description: Text("Commits appear here once you make the first one."))
        } else {
            Table(commits, selection: $selection) {
                TableColumn("Message") { commit in
                    HStack(spacing: 6) {
                        ForEach(commit.decorations, id: \.self) { ref in
                            Text(ref.replacingOccurrences(of: "HEAD -> ", with: ""))
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                        Text(commit.summary)
                    }
                }
                TableColumn("Author") { Text($0.author.name) }
                    .width(min: 100, ideal: 150)
                TableColumn("Date") { Text($0.author.date, format: .dateTime.day().month().year().hour().minute()) }
                    .width(min: 120, ideal: 150)
                TableColumn("Commit") { Text($0.shortID).font(.body.monospaced()).foregroundStyle(.secondary) }
                    .width(70)
            }
            .accessibilityIdentifier("history.table")
        }
    }
}
