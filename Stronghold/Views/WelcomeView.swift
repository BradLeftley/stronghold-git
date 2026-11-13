import GitEngine
import StrongholdCore
import SwiftUI

/// The first screen: the repository library, with ways to add, create or clone repositories.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var renaming: LibraryEntry?
    @State private var newName = ""

    var body: some View {
        let entries = model.library.search(query)
        VStack(spacing: 0) {
            header
            Divider()
            if model.library.entries.isEmpty {
                emptyLibrary
            } else {
                libraryList(entries)
            }
            Divider()
            gitStatus
                .font(.callout)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("welcome")
        .alert("Rename Repository", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { model.library.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("This only changes the name shown in Stronghold. The folder keeps its name.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stronghold").font(.title.weight(.semibold))
                Text("A native Git client for macOS.").foregroundStyle(.secondary)
            }
            Spacer()
            OpenRepositoryButton()
                .controlSize(.large)
            Button("Clone…") { model.isShowingCloneSheet = true }
                .controlSize(.large)
                .disabled(model.git == nil)
                .accessibilityIdentifier("cloneRepository")
        }
        .padding(20)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Repositories Yet", systemImage: "tray")
        } description: {
            Text("Add a folder that already has a Git repository, or clone one from a server. Repositories you open appear here.")
        }
        .accessibilityIdentifier("library.empty")
    }

    private func libraryList(_ entries: [LibraryEntry]) -> some View {
        VStack(spacing: 0) {
            TextField("Search repositories", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .accessibilityIdentifier("library.search")
            if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(entries) { entry in
                    LibraryRow(entry: entry, isAvailable: model.library.isAvailable(entry))
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.open(entry) } }
                        .contextMenu {
                            Button("Open") { Task { await model.open(entry) } }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            Button("Rename…") { newName = entry.name; renaming = entry }
                            Divider()
                            Button("Remove from Library") { model.library.remove(entry.id) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("library.row.\(entry.name)")
                }
                .listStyle(.inset)
                .accessibilityIdentifier("library.list")
            }
        }
    }

    @ViewBuilder private var gitStatus: some View {
        switch model.gitState {
        case .checking:
            ProgressView().controlSize(.small)
        case .ready(let version):
            Label("Using Git \(version.description)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("gitVersion")
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .accessibilityIdentifier("gitUnavailable")
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isAvailable ? "folder.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(isAvailable ? Color.accentColor : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text(isAvailable ? abbreviated(entry.path) : "Folder not found · \(abbreviated(entry.path))")
                    .font(.caption)
                    .foregroundStyle(isAvailable ? Color.secondary : .orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let opened = entry.lastOpened {
                Text(opened, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
