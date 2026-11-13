import GitEngine
import StrongholdCore
import SwiftUI

@main
struct StrongholdApp: App {
    @State private var model = AppModel()

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
