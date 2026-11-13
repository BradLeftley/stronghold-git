import GitEngine
import StrongholdCore
import SwiftUI

/// Staged and unstaged files. Read-only for now; staging and committing arrive with the changes view work.
struct ChangesView: View {
    let repository: RepositoryModel

    var body: some View {
        let status = repository.status
        if status.isClean {
            ContentUnavailableView("No Changes", systemImage: "checkmark.seal",
                                   description: Text("The working copy matches \(repository.headDescription)."))
                .accessibilityIdentifier("changes.clean")
        } else {
            List {
                if !status.conflicted.isEmpty {
                    Section("Conflicts") {
                        ForEach(status.conflicted) { FileRow(path: $0.path, badge: .conflicted) }
                    }
                }
                if !status.staged.isEmpty {
                    Section("Staged") {
                        ForEach(status.staged) { entry in
                            FileRow(path: entry.path, originalPath: entry.originalPath, badge: entry.stagedBadge ?? .modified)
                        }
                    }
                }
                if !status.unstaged.isEmpty {
                    Section("Unstaged") {
                        ForEach(status.unstaged) { entry in
                            FileRow(path: entry.path, badge: entry.unstagedBadge ?? .modified)
                        }
                    }
                }
            }
            .accessibilityIdentifier("changes.list")
        }
    }
}

private struct FileRow: View {
    let path: String
    var originalPath: String?
    let badge: ChangeBadge

    var body: some View {
        HStack(spacing: 8) {
            Text(badge.rawValue)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(color, in: .rect(cornerRadius: 4))
                .help(badge.label)
                .accessibilityLabel(badge.label)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                let folder = (path as NSString).deletingLastPathComponent
                if let originalPath {
                    Text("from \(originalPath)").font(.caption).foregroundStyle(.secondary)
                } else if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var color: Color {
        switch badge {
        case .added, .untracked: .green
        case .deleted: .red
        case .conflicted: .orange
        case .renamed, .copied: .blue
        default: .gray
        }
    }
}
