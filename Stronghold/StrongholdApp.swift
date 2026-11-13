import AppKit
import GitEngine
import StrongholdCore
import SwiftUI

@main
struct StrongholdApp: App {
    @State private var model: AppModel

    init() {
        // UI tests and screenshots point the library at a throwaway file so they never touch the real one.
        let override = ProcessInfo.processInfo.environment["STRONGHOLD_LIBRARY_PATH"]
        let storage = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? RepositoryLibrary.standardStorageURL
        _model = State(initialValue: AppModel(library: RepositoryLibrary(storageURL: storage)))
    }

    var body: some Scene {
        Window("Stronghold", id: "main") {
            RootView()
                .environment(model)
                .task { await launch() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenRepositoryButton()
                    .environment(model)
                    .keyboardShortcut("o")
                Button("Clone Repository…") { model.isShowingCloneSheet = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.git == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await model.repository?.refresh() }
                }
                .keyboardShortcut("r")
                .disabled(model.repository == nil)
            }
        }
    }

    /// Finds git, then opens a repository passed by UI tests or the command line.
    private func launch() async {
        await model.start()
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["STRONGHOLD_OPEN_REPOSITORY"], !path.isEmpty {
            await model.open(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let section = environment["STRONGHOLD_SECTION"], section == "history" {
            model.repository?.section = .history
        }
        #if DEBUG
        if environment["STRONGHOLD_SHOW_CLONE"] == "1" { model.isShowingCloneSheet = true }
        if let path = environment["STRONGHOLD_SELECT_FILE"], !path.isEmpty, let workingCopy = model.repository?.workingCopy {
            let area: ChangeArea = environment["STRONGHOLD_SELECT_AREA"] == "staged" ? .staged : .unstaged
            await workingCopy.select([FileSelection(path: path, area: area)])
        }
        #endif
        #if DEBUG
        await DebugSnapshot.captureIfRequested()
        #endif
    }
}

/// Shows the welcome screen until a repository is open.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let repository = model.repository {
                RepositoryView(repository: repository)
                    .id(repository.id)
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $model.isShowingCloneSheet) {
            CloneView()
                .environment(model)
        }
        .confirmationDialog("Create a Git repository here?", isPresented: Binding(
            get: { model.offerToInitialize != nil }, set: { if !$0 { model.offerToInitialize = nil } }
        ), titleVisibility: .visible, presenting: model.offerToInitialize) { folder in
            Button("Create Repository") { Task { await model.initializeRepository(at: folder) } }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("\(folder.lastPathComponent) isn’t a Git repository yet. Stronghold can run git init there.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Catch changes made while another app (a terminal, an editor) was in front.
            Task { await model.repository?.refreshStatus() }
        }
        .alert("Couldn't Open Repository", isPresented: Binding(
            get: { model.openError != nil },
            set: { if !$0 { model.openError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.openError ?? "")
        }
    }
}

/// "Open Repository…" with a folder picker, used by the welcome screen and the File menu.
struct OpenRepositoryButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPicking = false

    var body: some View {
        Button("Open Repository…") { isPicking = true }
            .disabled(model.git == nil)
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await model.open(url) }
                }
            }
            .accessibilityIdentifier("openRepository")
    }
}
