import GitEngine
import StrongholdCore
import SwiftUI

/// The sheet for cloning a repository: an address, a folder to clone into, and progress.
struct CloneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var folderName = ""
    @State private var folderNameEdited = false
    @State private var location = CloneView.savedLocation()
    @State private var isChoosingLocation = false

    private static let locationKey = "cloneLocation"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository").font(.title2.weight(.semibold))

            Form {
                TextField("Address", text: $address, prompt: Text("https://github.com/owner/repo.git"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("clone.address")
                    .onChange(of: address) { _, new in
                        if !folderNameEdited { folderName = Repository.defaultFolderName(forRemote: new) }
                    }
                LabeledContent("Clone into") {
                    HStack {
                        Text((location.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityIdentifier("clone.location")
                        Spacer()
                        Button("Choose…") { isChoosingLocation = true }
                    }
                }
                TextField("Folder name", text: $folderName)
                    .accessibilityIdentifier("clone.folder")
                    .onChange(of: folderName) { old, new in
                        if new != Repository.defaultFolderName(forRemote: address) { folderNameEdited = true }
                    }
            }
            .formStyle(.columns)
            .disabled(model.cloneState.isRunning)

            status

            HStack {
                Spacer()
                Button(model.cloneState.isRunning ? "Stop" : "Cancel") {
                    if model.cloneState.isRunning { model.cancelClone() } else { close() }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("clone.cancel")
                Button("Clone") { startClone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canClone)
                    .accessibilityIdentifier("clone.start")
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(isPresented: $isChoosingLocation, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { location = url }
        }
        .onDisappear { model.dismissCloneError() }
    }

    @ViewBuilder private var status: some View {
        switch model.cloneState {
        case .idle:
            Text(destination.map { "Will be cloned to \(($0.path as NSString).abbreviatingWithTildeInPath)" }
                 ?? "Enter an address and a folder name.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Cloning…")
            }
            .accessibilityIdentifier("clone.progress")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .accessibilityIdentifier("clone.error")
        }
    }

    private var destination: URL? {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return location.appendingPathComponent(name, isDirectory: true)
    }

    private var canClone: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && destination != nil
            && !model.cloneState.isRunning && model.git != nil
    }

    private func startClone() {
        guard let destination else { return }
        UserDefaults.standard.set(location.path, forKey: Self.locationKey)
        let remote = address
        Task {
            if await model.clone(remote: remote, to: destination) { close() }
        }
    }

    private func close() {
        model.isShowingCloneSheet = false
        dismiss()
    }

    private static func savedLocation() -> URL {
        if let path = UserDefaults.standard.string(forKey: locationKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
        return FileManager.default.fileExists(atPath: developer.path) ? developer : FileManager.default.homeDirectoryForCurrentUser
    }
}
